#!/usr/bin/perl -w

# Walk through the records in a file, substitute iffy chars in all subfields

use MARC::File::USMARC;
use MARC::Record;
use MARC::Field;
use Getopt::Long;
use Pod::Usage;
use strict;
use warnings;
# use utf8;
binmode STDOUT, ":utf8";

# Get options
my ($input_file) = get_options();

# Check that the file exists
if (!-e $input_file) {
  print "The file $input_file does not exist...\n";
  exit;
}

my $count = 0;

my $file = MARC::File::USMARC->in( $input_file );
while ( my $rec = $file->next() ) {
  
  my $new_rec = MARC::Record->new();
  $new_rec->encoding( 'UTF-8' );

  foreach my $field ($rec->fields()) {

    if ($field->is_control_field()) {

      $new_rec->append_fields($field);
      # print $field->tag(), " ", $field->data(), "\n";

    } else {

      # if ($field->tag() eq '020') { next; }

      my $new_field;
      my $first_subfield = 1;
      my @subfields = $field->subfields();
      if ($subfields[0]) {
        while (my $subfield = pop(@subfields)) {
          my ($code, $data) = @$subfield;
          if ($code && $data) {
            if ($first_subfield == 1) {
              $new_field = MARC::Field->new($field->tag(), $field->indicator(1), $field->indicator(2), $code => fix_data($data));
              $first_subfield = 0;
            } else {
              $new_field->add_subfields( $code => fix_data($data) );
            }
          }
        } 
      } else {
        next;
      }

      $new_rec->append_fields($new_field);
      $first_subfield = 1;

    }

  }

  print $new_rec->as_usmarc();
  $count++;  
}

# print "$count\n";

$file->close();
undef $file;

sub fix_data() {

  my $data = shift;
  my $out = '';
  my $prevchar = '';

  while ($data =~ m/(.)/g) {

    if (ord($1) == 95) {
      $out .= $prevchar . pack("U", 0x00E7); # ç
      $prevchar = '';
    } elsif (ord($1) == 162) {
      $out .= $prevchar . pack("U", 0x00D8); # Ø
      $prevchar = '';
    } elsif (ord($1) == 178) {
      $out .= $prevchar . pack("U", 0x00F8); # ø
      $prevchar = '';
    } elsif (ord($1) == 181) {
      $out .= $prevchar . pack("U", 0x00E6); # æ
      $prevchar = '';
    } elsif (ord($1) == 185) {
      $out .= $prevchar . ""; # Some kind of currency symbol?
      $prevchar = '';
    } elsif ((ord($prevchar) == 225) && (ord($1) == 101)) {
      $out .= "X"; # pack("U", 0x00E8); # è
      $prevchar = '';
    } elsif ((ord($prevchar) == 226) && (ord($1) == 97)) {
      $out .= "X"; # pack("U", 0x00C4); # Ä
      $prevchar = '';
    } elsif ((ord($prevchar) == 226) && (ord($1) == 101)) {
      $out .= pack("U", 0x00E9); # é
      $prevchar = '';
    } elsif ((ord($prevchar) == 226) && (ord($1) == 105)) {
      $out .= "i"; # ?
      $prevchar = '';
    } elsif ((ord($prevchar) == 226) && (ord($1) == 121)) {
      $out .= ""; # ?
      $prevchar = '';
    } elsif ((ord($prevchar) == 227) && (ord($1) == 101)) {
      $out .= pack("U", 0x00EA); # ê
      $prevchar = '';
    } elsif ((ord($prevchar) == 227) && (ord($1) == 105)) {
      $out .= "i"; # ?
      $prevchar = '';
    } elsif ((ord($prevchar) == 227) && (ord($1) == 111)) {
      $out .= "o"; # ?
      $prevchar = '';
    } elsif ((ord($prevchar) == 228) && (ord($1) == 97)) {
      $out .= pack("U", 0x00E3); # ã
      $prevchar = '';
    } elsif ((ord($prevchar) == 228) && (ord($1) == 110)) {
      $out .= pack("U", 0x00F1); # ñ
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 65)) {
      $out .= pack("U", 0x00C4); # Ä
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 79)) {
      $out .= pack("U", 0x00D6); # Ö
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 97)) {
      $out .= pack("U", 0x00E4); # ä
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 101)) {
      $out .= pack("U", 0x00EB); # ë
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 111)) {
      $out .= pack("U", 0x00F6); # ö
      $prevchar = '';
    } elsif ((ord($prevchar) == 232) && (ord($1) == 117)) {
      $out .= pack("U", 0x00FC); # ü
      $prevchar = '';
    } elsif ((ord($prevchar) == 234) && (ord($1) == 65)) {
      $out .= pack("U", 0x00C5); # Å
      $prevchar = '';
    } elsif ((ord($prevchar) == 234) && (ord($1) == 97)) {
      $out .= pack("U", 0x00E5); # å
      $prevchar = '';
    } else {
      $out .= $prevchar;
      $prevchar = $1;
    }

  }

  $out .= $prevchar;

  return $out;

}

sub get_options {

  # Options
  my $input_file = '';
  my $help = '';
  
  GetOptions (
    'i|infile=s' => \$input_file, 
    'h|?|help'  => \$help
  );

  pod2usage(-exitval => 0) if $help;
  pod2usage( -msg => "\nMissing Argument: -i, --infile required\n", -exitval => 1) if !$input_file;

  return ($input_file);

}

__END__

=head1 NAME
    
stats.pl - Produce stats about a file containing MARC-records.
        
=head1 SYNOPSIS
            
./char-rec.pl -i records.mrc > fixed.mrc
               
=head1 OPTIONS
              
=over 4
                                                   
=item B<-i, --infile>

Name of the MARC file to be read.

=item B<-h, -?, --help>
                                               
Prints this help message and exits.

=back
                                                               
=cut
