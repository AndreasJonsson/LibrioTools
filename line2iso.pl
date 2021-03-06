#!/usr/bin/env perl

# line2iso.pl
# Copyright 2009 Magnus Enger

# This is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This file is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this file; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

use MARC::File::USMARC;
use MARC::File::XML ( BinaryEncoding => 'utf8', RecordFormat => 'NORMARC' );
use MARC::Record;
use Getopt::Long;
use Modern::Perl;
use DelimExportCat;

# Options
my $file    = '';
my $encode  = '';
our $xml     = '';
my $limit   = '';
my $verbose = '';
my $debug   = '';
my $delimited = '';
my $accumulate_records = 0;

GetOptions (
  'a|acc'     => \$accumulate_records,
  'i|input=s' => \$file,
  'e|encode'  => \$encode,
  'l|limit=i' => \$limit,
  'x|xml'     => \$xml,
  'v|verbose' => \$verbose,
  'd|debug'   => \$debug,
  'b|delimited' => \$delimited,
);

if ( $encode ) {
    binmode STDOUT, ":encoding(UTF-8)";
}

sub trim {
   my $x = shift;
   $x =~ s/^\s+//;
   $x =~ s/\s+$//;
   return $x;
}

# Usage
if (!$file) {
  print "
This will turn a file of MARC-records in line format into ISO2709 or MARCXML.

Usage:
  ./line2iso.pl -i in.txt > out.mrc
  ./line2iso.pl -i in.txt -x > out.xml

Options:
  -i --input   = Input file
  -e, --encode = Apply: binmode STDOUT, :encoding(UTF-8)
  -a, --acc    = Accumulate records before starting output (only works with --delim).
  -l, --limit  = Limit outout to first n records
  -x --xml     = Output as MARCXML
  -v --verbose = Verbose output
  -d --debug   = Debug-output
  -b --delimited = Use delimited format of exportCat.txt

See also:
  yaz-marcdump http://www.indexdata.com/yaz/doc/yaz-marcdump.html

";
exit;
}

# Check that the file exists
if (!-e $file) {
  print "The file $file does not exist...\n";
  exit;
}

open(my $fh, "<:crlf", $file) or die "Couldn't open \"$file\": $!";

if ( $xml ) {
    say MARC::File::XML::header();
}

sub output {
    my $record = shift;
    if ($xml) {
        # print $record->as_xml_record(), "\n";
        say MARC::File::XML::record( $record );
    } else {
        print $record->as_usmarc(), "\n";
    }
}


if ($delimited) {

    my $dec = DelimExportCat->new( {
        'inputh'             => $fh,
        'limit'              => $limit ? $limit : undef,
        'verbose'            => $verbose,
        'accumulate_records' => $accumulate_records,
        'debug'              => $debug
    } );

    while (my $record = $dec->next_record()) {
        foreach my $warning ($record->warnings()) {
            say STDERR "Record " . $record->{record_nr} . " has warnings: " . $warning;
        }
        unless ($accumulate_records) {
            output($record);
        }
    }

    if ($accumulate_records) {
        my %records = %{$dec->get_records()};
        foreach my $record_id (keys %records) {
            my $record = $records{$record_id};
            output($record);
        }
    }

    say STDERR "Num records: " . $dec->record_count if $verbose;

} else {
# Start an empty record
    my $record = MARC::Record->new();

# Counter for records
    my $num = 0;

    my $line_count = 0;
    while (my $line = <$fh>) {

        chomp($line);

        say $line if $debug;

        # For some reason some lines begin with "**"
        # These seem to be errors of some kind, so we skip them
        if ($line =~ /^\*\*/) {
            next;
        }

        # Look for lines that begin with a ^ - these are record delimiters
        if ($line =~ /^\^/) {

            say "\nEND OF RECORD $num" if $verbose;

            # Make sure the encoding is set
            $record->encoding( 'UTF-8' );

            # Check that the record has a 245$a
            if ( $record->field( '245' ) && $record->field( '245' )->subfield( 'a' ) && $record->field( '245' )->subfield( 'a' ) ne '' ) {

                # Output the record in the desired format
                if ($xml) {
                    # print $record->as_xml_record(), "\n";
                    say MARC::File::XML::record( $record );
                } else {
                    print $record->as_usmarc(), "\n";
                }

                # Count the records
                $num++;

                # Check if we should quit here
                if ($limit && $limit == $num) {
                    last;
                }

            }

            # Start over with an empty record
            $record = MARC::Record->new();

            # Process the next line
            next;

        }

        # Some lines are just e.g. "*300 ", we skip these
        if (length($line) < 6) {
            next;
        }

        # Get the 3 first characters, this should be a MARC tag/field
        my $field = substr $line, 1, 3;

        if ($field ne "000" && $field ne "001" && $field ne "003" && $field ne "005" && $field ne "006" && $field ne "007" && $field ne "008") {

            # We have a data field, not a control field

            my $ind1  = substr $line, 4, 1;
            if ($ind1 eq " ") {
                $ind1 = "";
            }
            my $ind2  = substr $line, 5, 1;
            if ($ind2 eq " ") {
                $ind2 = "";
            }

            # Get everyting from character 7 and to EOL
            my $subs  = substr $line, 7;
            if ( $subs ) {

                # Split the string on field delimiters, $
                my @subfields = split(/\$/, $subs);
                my $subfield_count = 0;
                my $newfield = "";

                foreach my $subfield (@subfields) {

                    trim( $subfield );

                    # Skip short subfields
                    if (length($subfield) && length($subfield) < 1) {
                        next;
                    }

                    my $index = substr $subfield, 0, 1;
                    my $value = substr $subfield, 1;

                    if ($subfield_count == 0) {
                        # This is the first subfield, so we create a new field
                        $newfield = MARC::Field->new( $field, $ind1, $ind2, $index => $value );
                    } else {
                        # Subsequent subfields are added to the existing field
                        $newfield->add_subfields( $index, $value );
                    }

                    $subfield_count++;

                }

                $record->append_fields($newfield);

            }

        } else {

            # We have a control field

            my $value = substr $line, 4;
            my $field = MARC::Field->new($field, $value);
            $record->append_fields($field);

        }

        say "Line $line_count" if $verbose;
        $line_count++;

    }

# print "\n$num records processed\n";
}

if ( $xml ) {
    say MARC::File::XML::footer();
    print "\n";
}

