# Copyright 2016 Andreas Jonsson

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

package DelimExportCat;

use Moose;
use Carp;
use MARC::Record;
use MARC::Field;
use Data::Dumper;
use Modern::Perl;
use Text::CSV;
use DBI;

use ExplicitRecordNrField;

has 'inputh' => (
    is => 'ro',
    isa => 'FileHandle'
    );

has 'SUBFIELD_INDICATOR' => (
    is => 'ro',
    isa => 'RegexpRef',
    default => sub { return qr/\$/; }
    );

has 'limit' => (
    is => 'ro',
    isa => 'Maybe[Int]',
    );

has 'record_count' => (
    is => 'rw',
    isa => 'Int',
    default => 0
    );

has 'accumulate_records' => (
    is => 'ro',
    isa => 'Bool',
    default => 0
    );

has 'opt' => (
    is => 'ro',
    isa => 'Getopt::Long::Descriptive::Opts'
    );

has 'verbose' => (
    is => 'ro',
    isa => 'Bool'
    );

has 'debug' => (
    is => 'ro',
    isa => 'Bool'
    );

sub BUILD {
    my $self = shift;

    $self->{next_field} = undef;

    $self->{record_nr} = undef;
    $self->{completed_record} = undef;
    $self->{eof} = 0;

    $self->{records} = {};

    $self->{record_count} = 0;

    my $params = {
	sep_char => $self->opt->columndelimiter
    };

    if ($self->opt->rowdelimiter) {
	$params->{eol} = $self->opt->rowdelimiter;
    }
    if (defined($self->opt->quote) && $self->opt->quote ne '') {
	$params->{quote_char} = $self->opt->quote;
    }
    if (defined($self->opt->escape) && $self->opt->escape ne '') {
	$params->{escape_char} = $self->opt->escape;
    }

    $self->{csv} = Text::CSV->new($params);

    for (my $n = 0; $n < $self->opt->headerrows; $n++) {
	$self->csv->getline( $self->inputh );
    }
}

sub csv {
    my $self = shift;
    return $self->{csv};
}

sub next_record {
    my $self = shift;

    if ($self->{eof} || (defined($self->limit) && $self->record_count >= $self->limit)) {
        if ($self->verbose || $self->debug) {
            if ($self->{eof}) {
                say STDERR "End of file in next record."
            }
            if (defined($self->limit) && $self->record_count >= $self->limit) {
                say STDERR ("Reached limit of " . $self->limit);
            }
        }
        return undef;
    }

    my $record = undef;

    while (my $field  = $self->next_field()) {
	my $process_field = 1;
        unless ($record) {
	    $record = $self->new_record();
	    if ($field->{field_type} eq "000") {
		$process_field = 0;
		my $leader = $field->{content};
		if (length($leader) == 23) {
		    $leader .= ' ';  # Append the final "undefined" byte.
		}
		if (length($leader) != 24) {
		    if ($self->verbose || $self->debug) {
			carp "Leader length of record " . $self->{record_nr} . " is " . length($leader) . "!";
		    }
		    if (length($leader) < 24) {
			$leader .= ' ' x (24 - length($leader));
		    }
		}
		$record->leader($leader);
		$record->{record_nr} = $self->{record_nr} if ($self->debug);
	    } else {
		# carp "No leader on record number " . $record->{record_nr};
	    }
        } 
	if ($process_field) {
            my $mf;
            if ($field->{field_type} =~ /^00/) {
                $mf = MARC::Field->new( $field->{field_type}, $field->{content} );
            } else {
                my @field_data = eval { $self->field_data( $field->{content} ) };

		if (scalar(@field_data) == 0) {
		    next;
		}

                if ($@) {
                    carp $@;
                    next; # Ignore fields with errors.
                }

                $mf = MARC::Field->new( $field->{field_type},
                                        $field->{indicator1},
                                        $field->{indicator2},
                                        @field_data );
                # $self->check_field( $mf );
            }
            $record->append_fields($mf);
        }
    }

    $self->record_count($self->record_count + 1);

    $record->encoding( 'UTF-8' );

    if ($self->{accumulate_records}) {
        $self->{records}->{$self->{completed_record}} = $record;
    }

    $self->attach_record_id( $record );

    return $record;
}

sub next_field {
    my $self = shift;

    #local $/ = "!*!\n";

    my $fh = $self->inputh;

    $! = undef;

    my $line;

    if ($self->{next_field}) {
        my $next_field = $self->{next_field};
        $self->{next_field} = undef;
        $self->{record_nr} = $next_field->{record_nr};
        return $next_field;
    }

    #$line = <$fh>;
    my $columns = $self->csv->getline( $fh );

    unless (defined($columns)) {
        if (!$self->csv->eof && !$self->csv->status) {
            croak "Error when reading input: " . $self->csv->error_diag;
        }
        $self->{eof} = 1;
        $self->{completed_record} = $self->{record_nr};
        $self->{record_nr} = undef;
        return undef;
    }

    my @col = @$columns;

    if ($self->opt->format ne 'micromarc') {
	unless (+@col == 7) {
	    croak "Failed to parse input line of field number " . $fh->input_line_number() . ": '" . $line . "'";
	}
    }

    my $field;

    if ($self->opt->format eq 'micromarc') {
	$field = {
	    record_nr  => $col[0],
	    field_type => $col[1],
	    indicator1 => $col[2],
	    indicator2 => $col[3],
	    content    => $col[4]
	};
	# XXX Clean non-breakable spaces.
	if ($field->{field_type} eq '020') {
	    $field->{content} =~ s/\x{001f}//g;
	}
	if ($field->{field_type} eq '000' && length($field->{content}) != 24) {
	    my $s = $field->{content};
	    if (length($s) > 24) {
		print STDERR "Leader too long: '$s'\n";
		$s = substr($s, length($s) - 24);
		$field->{content} = $s;
	    } else {
		#print STDERR "Leader too short: '$s'\n";
		#$field->{content} = ' ' x 24;
	    }
	}

    } else {
	$field = {
	    record_nr  => $col[0],
	    index1     => $col[1], # TODO I don't know what these are for.
	    field_type => $col[2],
	    index2     => $col[3], # TODO I don't know what these are for.
	    content    => $col[4],
	    indicator1 => $col[5],
	    indicator2 => $col[6]
	};
    };

    if (defined($self->{record_nr}) && $self->{record_nr} != $field->{record_nr}) {
        $self->{next_field} = $field;
        $self->{completed_record} = $self->{record_nr};
        $self->{record_nr} = undef;
        return undef;
    }

    $self->{record_nr} = $field->{record_nr} unless defined($self->{record_nr});

    return $field;
}

sub field_data {
    my $self = shift;
    my $content = shift;

    my @subfields = split($self->{SUBFIELD_INDICATOR}, $content);

    if (+@subfields == 0) {
        #croak "Field without subfields: " . $self->{record_nr};
	return ();
    }

    if (length($subfields[0]) != 0) {
        croak "There is content before first subfield: '$content' record nr: " . $self->{record_nr};
    }

    shift @subfields;

    my @subfield_data;
    for ( @subfields ) {
        if ( length > 0 ) {
            push( @subfield_data, substr($_,0,1),substr($_,1) );
        } else {
            carp "Entirely empty subfield found: $content record nr: " . $self->{record_nr};
        }
    }

    return @subfield_data;
}

sub check_field {
    my $self = shift;
    my $field = shift;

    if (!$field->is_control_field()) {
        foreach my $subfield ($field->subfields()) {
            if ($subfield->[1] =~ /\([^)]*$/) {
                carp "Field with unbalanced paranthesis in record " . $self->{record_nr} . " tag: " . $field->tag();
            }
        }
    }
}

sub new_record {
    my $self = shift;

    if ($self->{accumulate_records}) {
        my $r = $self->{records}->{$self->{record_nr}};
        if (defined($r)) {
            carp "Record " . $self->record_nr . " already exists!";
            return $r;
        }
    }

    return MARC::Record->new();
}

sub get_records {
    my $self = shift;
    croak "I am not accumulating records!" unless $self->{accumulate_records};
    return $self->{records};
}

sub attach_record_id {
    my $self = shift;
    my $record = shift;

    my $field = MARC::Field->new( $ExplicitRecordNrField::RECORD_NR_FIELD,
                                  ' ',
                                  ' ',
                                  ( $ExplicitRecordNrField::RECORD_NR_SUBFIELD => $self->{completed_record} ));
    $record->append_fields( $field );
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

