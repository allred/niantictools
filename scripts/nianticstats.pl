#!/usr/bin/perl
# queries Niantic messages from gmail via IMAP, compiles stats, emails result
# assumes the local mail delivery system will deliver the email report properly
# also prints the report to stdout
# TODO:
# - optimize speed
# - justify table

my $usage = <<'EOF';
instructions for install/usage:
 - sudo cpan install MIME::Lite
 - sudo cpan install Net::IMAP::Client
 - chmod u+x nianticstats.pl
 - ./nianticstats.pl youremail@gmail.com yourpassword
EOF

use strict;
use warnings;
use Data::Dumper;
use MIME::Lite;
use Net::IMAP::Client;

my $user_gmail = shift @ARGV;
my $pass_gmail = shift @ARGV;
my $mailto = $user_gmail;
my $mailfrom = $user_gmail;
unless ($user_gmail && $pass_gmail) {
  die $usage;
}

# search for Niantic emails

my $client_imap = Net::IMAP::Client->new(
  server => 'imap.gmail.com',
  user => $user_gmail,
  pass => $pass_gmail,
  ssl => 1,
  port => 993,
) or die "could not connect";
$client_imap->login or die "login failed";
$client_imap->select('[Gmail]/All Mail');
my $messages = $client_imap->search({
  subject => 'Ingress notification - Entities Destroyed by',
});
my $summaries = $client_imap->get_summaries($messages);
my %destroyers;
my $total_resos_destroyed = 0;
my $total_links_destroyed = 0;
my $total_mods_destroyed = 0;
my $total_emails = scalar @$summaries;
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
  
  # subject

  my $subject = $summary->subject;
  $subject =~ qr/by (.*)$/;
  my $destroyer = $1;
  $destroyers{$destroyer}{resos} += $resos_destroyed_this_summary;
  $destroyers{$destroyer}{links} += $links_destroyed_this_summary;
  $destroyers{$destroyer}{mods} += $mods_destroyed_this_summary;

  $total_resos_destroyed += $resos_destroyed_this_summary;
  $total_links_destroyed += $links_destroyed_this_summary;
  $total_mods_destroyed += $mods_destroyed_this_summary;
  $count_processed++;
  print STDERR "emails processed: $count_processed/$total_emails resos: $total_resos_destroyed links: $total_links_destroyed mods: $total_mods_destroyed\n";
}
my $total_destroyers = scalar keys %destroyers;
my $text_report = '';
$text_report .= "[total destroyers: $total_destroyers]\n";
$text_report .= "[total resos destroyed: $total_resos_destroyed]\n";
$text_report .= "[total links destroyed: $total_links_destroyed]\n";
$text_report .= "[total mods destroyed: $total_mods_destroyed]\n";
$text_report .= "----------------------------\n";
$text_report .= "[DESTROYER RESOS LINKS MODS]\n";
$text_report .= "----------------------------\n";
foreach my $destroyer (sort { $destroyers{$b}{resos} <=> $destroyers{$a}{resos} } keys %destroyers) {
  $text_report .= "$destroyer $destroyers{$destroyer}{resos} $destroyers{$destroyer}{links} $destroyers{$destroyer}{mods}\n";
}
print $text_report;

# send mail

my $mimelite = MIME::Lite->new(
  Data => $text_report,
  From => $mailfrom,
  Subject => "Destroyers Report: $total_destroyers destroyers, $total_resos_destroyed resos, $total_links_destroyed links, $total_mods_destroyed mods",
  To => $mailto,
  Type => 'text',
);
$mimelite->send;
