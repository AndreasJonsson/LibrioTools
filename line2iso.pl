#!/usr/bin/perl

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
use Getopt::Long::Descriptive;
use Modern::Perl;
use DelimExportCat;
use Scalar::Util qw(blessed);

my ($opt, $usage) = describe_options(
    '%c %o <some-arg>',
    [ 'acc', "Accumulate records" ],
    [ 'limit=i', 'Limit the number of records to output.' ],
    [ 'xml', 'Produce marc-xml output.' ],
    [ 'dir=s', "table directory", { required => 1  } ],
    [ 'table=s', 'table name', { required => 1 } ],
    [ 'format=s', 'Source format', { default => 'libra' } ],
    [ 'ext=s',     'table filename extension', { default => '.txt' } ],
    [ 'columndelimiter=s', 'column delimiter',  { default => '!*!' } ],
    [ 'rowdelimiter=s',  'row delimiter'      ],
    [ 'encoding=s',  'character encoding',      { default => 'utf-8' } ],
    [ 'output=s', 'file name of output' ],
    [ 'quote=s',  'quote character' ],
    [ 'bom', 'use bom', { default => 0 } ],
    [ 'escape=s', 'escape character', { default => undef } ],
    [ 'headerrows=i', 'number of header rows',  { default => 0 } ],
    [ 'delimited', 'use DelimExportCat class',  { default => 1 } ],
           [],
           [ 'verbose|v',  "print extra stuff"            ],
           [ 'debug|d',    "print debug stuff"            ],
           [ 'help',       "print usage message and exit", { shortcircuit => 1 } ],
         );

print $usage->text if ($opt->help);

if (!defined $opt->output) {
    if ($opt->xml) {
	binmode STDOUT, ":encoding(utf-8)";
    } else {
	binmode STDOUT;
    }
} else {
    binmode STDOUT, ":utf8";
}

sub trim {
   my $x = shift;
   $x =~ s/^\s+//;
   $x =~ s/\s+$//;
   return $x;
}

my $filename = $opt->dir . '/' . $opt->table . $opt->ext;

say STDERR "filename: $filename";

# Check that the file exists
if (!-e $filename) {
  print "The file " . $filename . " does not exist...\n";
  exit;
}

my $fh;
if ($opt->bom) {
    use File::BOM;
    open($fh, "<:encoding(" . $opt->encoding . "):via(File::BOM)", $filename) or die "Couldn't open \"" . $filename . "\": $!";
} else {
    open($fh, "<:encoding(" . $opt->encoding . ")", $filename) or die "Couldn't open \"" . $filename . "\": $!";
}

my $output_fh;
if (defined $opt->output) {
    open $output_fh, ">", $opt->output;
    binmode $output_fh;
    if ($opt->xml) {
	binmode $output_fh, ":encoding(utf-8)";
    } else {
	binmode $output_fh, ":utf8";
    }
} else {
    $output_fh = \*STDOUT;
}

if ( $opt->xml ) {
    say $output_fh MARC::File::XML::header();
}

sub output {
    my $record = shift;
    if ($opt->xml) {
        # print $record->as_xml_record(), "\n";
        say $output_fh MARC::File::XML::record( $record );
    } else {
        print $output_fh  MARC::File::USMARC::encode( $record );
    }
}


if ($opt->delimited) {

    my $dec = DelimExportCat->new( {
        'inputh'             => $fh,
        'limit'              => $opt->limit ? $opt->limit : undef,
        'verbose'            => $opt->verbose,
        'accumulate_records' => $opt->acc,
        'opt'                => $opt,
        'debug'              => $opt->debug
    } );

    while (my $record = $dec->next_record()) {
	if (blessed $record) {
	    foreach my $warning ($record->warnings()) {
		say STDERR "Record " . $record->{record_nr} . " has warnings: " . $warning;
	    }
	    unless ($opt->acc) {
		output($record);
	    }
	}
    }

    if ($opt->format eq 'aleph') {
	$dec->aleph_analyze;
    }

    if ($opt->acc) {
        my %records = %{$dec->get_records()};
        foreach my $record_id (keys %records) {
            my $record = $records{$record_id};
            output($record);
        }
    }

    say STDERR "Num records: " . $dec->record_count if $opt->verbose;

} else {
# Start an empty record
    my $record = MARC::Record->new();

# Counter for records
    my $num = 0;

    my $line_count = 0;
    while (my $line = <$fh>) {

        chomp($line);

        say $line if $opt->debug;

        # For some reason some lines begin with "**"
        # These seem to be errors of some kind, so we skip them
        if ($line =~ /^\*\*/) {
            next;
        }

        # Look for lines that begin with a ^ - these are record delimiters
        if ($line =~ /^\^/) {

            say "\nEND OF RECORD $num" if $opt->verbose;

            # Make sure the encoding is set
            $record->encoding( 'UTF-8' );

            # Check that the record has a 245$a
            if ( $record->field( '245' ) && $record->field( '245' )->subfield( 'a' ) && $record->field( '245' )->subfield( 'a' ) ne '' ) {

                # Output the record in the desired format
                if ($opt->xml) {
                    # print $record->as_xml_record(), "\n";
                    say MARC::File::XML::record( $record );
                } else {
                    print $record->as_usmarc(), "\n";
                }

                # Count the records
                $num++;

                # Check if we should quit here
                if ($opt->limit && $opt->limit == $num) {
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

        say "Line $line_count" if $opt->verbose;
        $line_count++;

    }

# print "\n$num records processed\n";
}

if ( $opt->xml ) {
    say $output_fh MARC::File::XML::footer();
    print "\n";
}

