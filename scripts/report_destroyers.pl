#!/usr/bin/perl
# compiles stats on destroyed items
# queries Niantic messages from gmail via IMAP, compiles stats, emails result
# assumes the local mail delivery system will deliver the email report properly
# also prints the report to stdout
# TODO:
# - optimize speed
# - justify table
# - send email via gmail?

my $usage = <<'EOS';

instructions for install/usage:
 - sudo cpan install Email::MIME::Encodings Getopt::Long MIME::Lite Net::IMAP::Client
 - chmod u+x report_destroyers.pl
 - GMAILPASS=yourpassword ./report_destroyers.pl --user youremail@gmail.com

command line options:
 --cachefile : supply a path to a write-able file to cache email bodies 
 --help
 --imapdir   : search a user-defined label/folder instead of All Mail 
 --pass      : supply password, obvious warning: can be seen in ps output!
 --rloc      : get stats on destroyed portal locations, arg is number of locs 
 --rmax      : max number of of emails to process (for debugging)
 --sendemail : sends the report via smtp to the gmail user specified
 --user      : your gmail address, also currently the mailto for sendemail
EOS
my $epoch_start = time;

use strict;
use warnings;
use Data::Dumper;
use Email::MIME::Encodings;
use Getopt::Long;
use MIME::Lite;
use Net::IMAP::Client;
use Storable qw(store retrieve);

my %args;
GetOptions(\%args, qw(
  cachefile=s
  help
  imapdir=s
  pass=s
  rloc=s
  rmax=s
  sendemail
  user=s
));

my $user_gmail = $args{user};
my $pass_gmail = $ENV{GMAILPASS} || $args{pass};
my $mailto = $args{user};
my $mailfrom = $args{user};
if (!$user_gmail || !$pass_gmail || $args{help}) {
  die $usage;
}
my $imapdir = $args{imapdir} || '[Gmail]/All Mail';

# search for Niantic emails

my $client_imap = Net::IMAP::Client->new(
  server => 'imap.gmail.com',
  user => $user_gmail,
  pass => $pass_gmail,
  ssl => 1,
  port => 993,
) or die "could not connect";
$client_imap->login or die "login failed";
$client_imap->select($imapdir);
print STDERR "logged in as $user_gmail, searching $imapdir\n";
my $messages = [];

# search for the various incarnations of destroyer reports

foreach my $hashref_search (
  {
    subject => 'Ingress notification - Entities Destroyed by',
  },
  {
    from => 'ingress-support@google.com',
    subject => 'Damage Report',
  },
) {
  print STDERR "searching $imapdir for '$hashref_search->{subject}'\n";
  my $messages_search = $client_imap->search($hashref_search);
  push @$messages, @$messages_search;
}

my $count_messages = scalar @$messages;
print STDERR "getting summaries for $count_messages emails\n";
my $summaries = $client_imap->get_summaries($messages);
my %destroyers;
my $total_resos_destroyed = 0;
my $total_links_destroyed = 0;
my $total_mods_destroyed = 0;
my $total_emails = 0;
my %locations_destroyed = ();
if (defined $summaries && ref $summaries eq 'ARRAY') {
  $total_emails = scalar @$summaries;
}
else {
  die "no Niantic emails found in $imapdir";
}
my $count_processed = 0;
my %urls_found = ();
my %latlngs_found = ();
my $cache = {};
if ($args{cachefile} && -r $args{cachefile}) {
  print STDERR "reading from cachefile $args{cachefile}\n";
  $cache = retrieve($args{cachefile});
}
foreach my $summary (@$summaries) {
  if ($args{rmax} && $count_processed >= $args{rmax}) { last; }
  my $message_id = $summary->message_id;
  my $resos_destroyed_this_summary = 0;
  my $links_destroyed_this_summary = 0;
  my $mods_destroyed_this_summary = 0;
  my $destroyer = 'FIXMEUNKNOWN';

  # get the text and html parts of the email

  my $body_text;
  my $body_html;

  # try to read from cache

  if (
     $args{cachefile}
     && $cache->{$message_id}
     && $cache->{$message_id}->{body_text}
     && $cache->{$message_id}->{body_html}
  ) {
    $body_text = $cache->{$message_id}->{body_text};
    $body_html = $cache->{$message_id}->{body_html};
  }

  # or read from gmail

  else {
    my $hash_part = $client_imap->get_parts_bodies($summary->uid, ['1', '2']);
    $body_text = ${$hash_part->{1}};
    $cache->{$message_id}->{body_text} = $body_text; 
    $body_html = '';

    # process html part for further data points (URLs, etc) 

    if ($hash_part->{2}) {
      my $subpart_html = $summary->get_subpart('2');
      my $transfer_encoding_content_html = $subpart_html->transfer_encoding;
      my $string_html = ${$hash_part->{2}};
      $body_html = Email::MIME::Encodings::decode($transfer_encoding_content_html, ${$hash_part->{2}});
      $cache->{$message_id}->{body_html} = $body_html; 
    }
  }

  my $subject = $summary->subject;

  # gen1 emails had destroyer in subject, sigh...

  if ($subject =~ qr/by (.*)$/) {
    $destroyer = $1;
  }

  # gen2 emails are sub optimal

  elsif ($body_text =~ qr/by (\S+)/) {
    $destroyer = $1;
  }

  # get all URLs in the html part 
  # get latitude/longitude data from those links
  #print Dumper $body_html;

  while ($body_html =~ /href="(http.*?)"/gs) {
    my $url = $1;
    $urls_found{$url}{count}++;
    my $lat;
    my $lng;
    if ($args{rloc} && $url =~ /intel/) {

      # first gen loc links

      if ($url =~ /latE6=(\S+)&lngE6=(\S+)&/) { 
        $lat = $1;
        $lng = $2;
      }

      # second gen loc links

      elsif ($url =~/ll=(\S+),(\S+)&pll=(\S+),(\S+)&/) {
        $lat = $1;
        $lng = $2;
      }
      if ($lat && $lng) {

        # remove decimal from newer latlongs so new/old keys match 

        $lat =~ s/\.//;
        $lng =~ s/\.//;
        $latlngs_found{"$lat|$lng"}{url} = $url;
        $latlngs_found{"$lat|$lng"}{firstdate} ||= $summary->date;
        $latlngs_found{"$lat|$lng"}{lastdate} ||= $summary->date;
        $latlngs_found{"$lat|$lng"}{count}++;
      }
    }
  }

  # this gets the item count from lines like:
  # 2 Resonator(s) destroyed by ...
  # and other similar strings

  while ($body_text =~ /(\d+?)\s+Resonator(\(s\))?\s*(were)?\s*destroy/gs) {
    my $num_resos_destroyed = $1;
    $resos_destroyed_this_summary += $num_resos_destroyed;  
  }

  # find Links destroyed

  while ($body_text =~ /Your Link has been destroyed/gs) {
    $links_destroyed_this_summary++;
  }
  while ($body_text =~ /(\d+?)\s+Link(\(s\))?\s*destroy/gs) {
    $links_destroyed_this_summary += $1;
  }

  # find Mods destroyed

  while ($body_text =~ /(\d+?)\s+Mod(\(s\))?\s*(were)?\s*destroy/gs) {
    $mods_destroyed_this_summary += $1;
  }

#print Dumper {
#body => $body_text,
#rdts => $resos_destroyed_this_summary,
#mdts => $mods_destroyed_this_summary,
#ldts => $links_destroyed_this_summary,
#};
  
  $destroyers{$destroyer}{resos} += $resos_destroyed_this_summary || 0;
  $destroyers{$destroyer}{links} += $links_destroyed_this_summary || 0;
  $destroyers{$destroyer}{mods} += $mods_destroyed_this_summary || 0;
  $destroyers{$destroyer}{date_first_notification} ||= $summary->date;
  $destroyers{$destroyer}{date_last_notification} = $summary->date;

  $total_resos_destroyed += $resos_destroyed_this_summary;
  $total_links_destroyed += $links_destroyed_this_summary;
  $total_mods_destroyed += $mods_destroyed_this_summary;
  $count_processed++;
  print STDERR "emails processed: $count_processed/$total_emails resos: $total_resos_destroyed links: $total_links_destroyed mods: $total_mods_destroyed\n";
}

if ($args{cachefile}) {
  print STDERR "writing to cachefile $args{cachefile}\n";
  store $cache, $args{cachefile};
}
my $total_destroyers = scalar keys %destroyers;

my $text_report = <<"EOS";
[total destroyers: $total_destroyers]
[total resos destroyed: $total_resos_destroyed]
[total links destroyed: $total_links_destroyed]
[total mods destroyed: $total_mods_destroyed]
EOS

if ($args{rloc}) {
  $text_report .= <<"EOS";
-----------
[LOCATIONS]
-----------
EOS

  my $count_locations_shown = 0;
  foreach my $latlng (sort { $latlngs_found{$b}{count} <=> $latlngs_found{$a}{count} } keys %latlngs_found) {
    my $url = $latlngs_found{$latlng}{url};
    if ($count_locations_shown >= $args{rloc}) { next; }
    if ($url eq 'http://www.ingress.com/intel') { next; }
    if ($url eq 'http://support.google.com/ingress') { next; }
    $text_report .= "$url $latlngs_found{$latlng}{count}\n";
    $count_locations_shown++;
  }
}


$text_report .= <<"EOS";
-----------------------------------------
[DESTROYER RESOS LINKS MODS LATEST FIRST]
-----------------------------------------
EOS

foreach my $destroyer (sort { $destroyers{$b}{resos} <=> $destroyers{$a}{resos} } keys %destroyers) {
  $text_report .= "$destroyer $destroyers{$destroyer}{resos} $destroyers{$destroyer}{links} $destroyers{$destroyer}{mods} ($destroyers{$destroyer}{date_last_notification}) ($destroyers{$destroyer}{date_first_notification})\n";
}
my $epoch_end = time;
my $secs_report_duration = $epoch_end - $epoch_start;
my $mins_report_duration = $secs_report_duration / 60;
print STDERR "report generated in ${mins_report_duration}m (${secs_report_duration}s)\n";
print $text_report;

# send mail

my $mimelite = MIME::Lite->new(
  Data => $text_report,
  From => $mailfrom,
  Subject => "Destroyers Report: $total_destroyers destroyers, $total_resos_destroyed resos, $total_links_destroyed links, $total_mods_destroyed mods",
  To => $mailto,
  Type => 'text',
);
if ($args{sendemail}) {
  $mimelite->send;
}
