#!/usr/bin/perl
# queries Niantic messages from gmail via IMAP, compiles stats, emails result
#
# instructions for install/usage:
# - sudo cpan install MIME::Lite
# - sudo cpan install Net::IMAP::Client
# - chmod u+x nianticstats.pl
# - ./nianticstats.pl
#
# assumes the local mail delivery system will deliver the email report properly
# also prints the report to stdout

use strict;
use warnings;
use Data::Dumper;
use MIME::Lite;
use Net::IMAP::Client;

my $user_gmail = shift @ARGV;
my $pass_gmail = shift @ARGV;
my $mailto = $user_gmail;
my $mailfrom = $user_gmail;

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
my $count_destroyed = 0;
foreach my $summary (@$summaries) {
  my $subject = $summary->subject;
  $subject =~ qr/by (.*)$/;
  my $destroyer = $1;
  $destroyers{$destroyer}++;
  $count_destroyed++;
}
my $count_destroyers = scalar keys %destroyers;
my $text_report = '';
$text_report .= "[total items destroyed: $count_destroyed]\n";
$text_report .= "[total destroyers: $count_destroyers]\n";
foreach my $destroyer (sort { $destroyers{$b} <=> $destroyers{$a} } keys %destroyers) {
  $text_report .= "$destroyer $destroyers{$destroyer}\n";
}
print $text_report;

# send mail

my $mimelite = MIME::Lite->new(
  Data => $text_report,
  From => $mailfrom,
  Subject => "Destroyers Report: $count_destroyed items, $count_destroyers destroyers",
  To => $mailto,
  Type => 'text',
);
$mimelite->send;
