#!/usr/bin/perl
# compiles stats on destroyed items
# queries Niantic messages from gmail via IMAP, compiles stats, emails result
# assumes the local mail delivery system will deliver the email report properly
# also prints the report to stdout
# TODO:
# - optimize speed
# - justify table

my $usage = <<'EOS';

instructions for install/usage:
 - sudo cpan install Getopt::Long MIME::Lite Net::IMAP::Client
 - chmod u+x report_destroyers.pl
 - GMAILPASS=yourpassword ./report_destroyers.pl --user youremail@gmail.com

command line options:
 --help
 --imapdir   : search a user-defined label/folder instead of All Mail 
 --pass      : supply password, warning, can be seen in ps output!
 --sendemail : sends the report via smtp to the gmail user specified
 --user
EOS
my $epoch_start = time;

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use MIME::Lite;
use Net::IMAP::Client;

my %args;
GetOptions(\%args, qw(
  help
  imapdir=s
  pass=s
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
my $messages = $client_imap->search({
  subject => 'Ingress notification - Entities Destroyed by',
});
my $summaries = $client_imap->get_summaries($messages);
my %destroyers;
my $total_resos_destroyed = 0;
my $total_links_destroyed = 0;
my $total_mods_destroyed = 0;
my $total_emails = 0;
if (defined $summaries && ref $summaries eq 'ARRAY') {
  $total_emails = scalar @$summaries;
}
else {
  die "no Niantic emails found in $imapdir";
}
my $count_processed = 0;
foreach my $summary (@$summaries) {
  my $resos_destroyed_this_summary = 0;
  my $links_destroyed_this_summary = 0;
  my $mods_destroyed_this_summary = 0;

  # get the text part of the email

  my $hash_part = $client_imap->get_parts_bodies($summary->uid, ['1']);
  my $body_text = ${$hash_part->{1}};

  # this gets the item count from lines like:
  # 2 Resonator(s) destroyed by ...

  while ($body_text =~ /(\d+?)\s+Resonator/gs) {
    my $num_resos_destroyed = $1;
    $resos_destroyed_this_summary += $num_resos_destroyed;  
  }

  # find Links destroyed

  while ($body_text =~ /Your Link has been destroyed/gs) {
    $links_destroyed_this_summary++;
  }

  # find Mods destroyed

  while ($body_text =~ /(\d+?)\s+Mod/gs) {
    $mods_destroyed_this_summary += $1;
  }
  
  # grab subject, agent id is the key for destroyer stats

  my $subject = $summary->subject;
  $subject =~ qr/by (.*)$/;
  my $destroyer = $1;
  $destroyers{$destroyer}{resos} += $resos_destroyed_this_summary;
  $destroyers{$destroyer}{links} += $links_destroyed_this_summary;
  $destroyers{$destroyer}{mods} += $mods_destroyed_this_summary;
  $destroyers{$destroyer}{date_first_notification} ||= $summary->date;
  $destroyers{$destroyer}{date_last_notification} = $summary->date;

  $total_resos_destroyed += $resos_destroyed_this_summary;
  $total_links_destroyed += $links_destroyed_this_summary;
  $total_mods_destroyed += $mods_destroyed_this_summary;
  $count_processed++;
  print STDERR "emails processed: $count_processed/$total_emails resos: $total_resos_destroyed links: $total_links_destroyed mods: $total_mods_destroyed\n";
}
my $total_destroyers = scalar keys %destroyers;

my $text_report = <<"EOS";
[total destroyers: $total_destroyers]
[total resos destroyed: $total_resos_destroyed]
[total links destroyed: $total_links_destroyed]
[total mods destroyed: $total_mods_destroyed]
-----------------------------------
[DESTROYER RESOS LINKS MODS LATEST]
-----------------------------------
EOS

foreach my $destroyer (sort { $destroyers{$b}{resos} <=> $destroyers{$a}{resos} } keys %destroyers) {
  $text_report .= "$destroyer $destroyers{$destroyer}{resos} $destroyers{$destroyer}{links} $destroyers{$destroyer}{mods} ($destroyers{$destroyer}{date_last_notification})\n";
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
