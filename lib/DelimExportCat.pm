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
use utf8;

use ExplicitRecordNrField;

has 'inputh' => (
    is => 'ro',
    isa => 'FileHandle'
    );

has 'SUBFIELD_INDICATOR' => (
    is => 'rw',
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

    $self->{process} = sub { return $_[1]; };

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

    if ($self->opt->format eq 'aleph') {
	$self->{getline} = \&_getline_aleph;
	$self->SUBFIELD_INDICATOR(qr/\$\$/);
	$self->{unknown} = {};
	$self->{process} = \&_aleph_process_record;
	$self->{aleph_analyze} = {};
    } else {
	$self->{getline} = \&_getline_csv;
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

    FIELD: while (my $field  = $self->next_field()) {
	my $process_field = 1;

	next FIELD if ($field->{field_type} eq '');
	
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
		$record->encoding( 'UTF-8' ) if ($self->opt->format eq 'aleph');
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

    if (defined $record) {

	$self->record_count($self->record_count + 1);

	if ($self->{accumulate_records}) {
	    $self->{records}->{$self->{completed_record}} = $record;
	}

	$self->attach_record_id( $record );

	$record = $self->process_record( $record );

	return $record;
    }

    return 1;
}

sub process_record {
    my $self = shift;
    my $record = shift;

    return $self->{process}->($self, $record);
}

sub getline {
    my $self = shift;
    my $fh = shift;

    return $self->{getline}->($self, $fh);
}
 
sub _getline_csv {
    my $self = shift;
    my $fh = shift;

    return $self->csv->getline( $fh );
}

sub aleph_analyze {
    my $self = shift;
    for my $field (keys %{$self->{aleph_stat}}) {
	print "----------------------------------------- $field -------------------------------------\n";

	my @s = ();
	while (my ($v, $n) = each %{$self->{aleph_stat}->{$field}}) {
	    push @s, [$v, $n];
	}
	@s = sort { $b->[1] - $a->[1] } @s;

	for my $s0 (@s) {
	    print $s0->[0], ": ", $s0->[1], "\n";
	}
    }
}

sub add_to_comment {
    my $field = shift;
    my $text = shift;
    if (defined $field->subfield('z')) {
	$text = $field->subfield('z') . "\n\n" . $text;
	$field->delete_subfield('z');
    }
    $field->add_subfields('z', $text);
}

sub _aleph_process_record {
    my $self = shift;
    my $record = shift;

    my @items = ();
    
    for my $field ($record->field('952')) {
	$record->delete_fields($field);

	for my $sf ($field->subfields()) {
	    next if $sf->[0] eq 'm' || $sf->[0] eq '5' || $sf->[0] eq '8' || $sf->[0] eq 'L';
	    my $stat = $self->{aleph_stat}->{$sf->[0]};
	    if (! defined $stat) {
		$stat = {};
		$self->{aleph_stat}->{$sf->[0]} = $stat;
	    }

	    my $n = $stat->{$sf->[1]};
	    if (!defined $n) {
		$n = 1;
	    } else {
		$n++;
	    }
	    $stat->{$sf->[1]} = $n;
	}

=h1	
 b:  nummer 'Vol 1','4/96'
----------------------------------------- f -------------------------------------
01: 16222
14: 5513
12: 181
13: 1
----------------------------------------- 4 -------------------------------------
Papperskopia.: 3
----------------------------------------- P -------------------------------------
Saknas: 2
Order påbörja: 2
----------------------------------------- h -------------------------------------
----------------------------------------- h -------------------------------------
Bilaga: 6
Ryska: 5
Del 2: 5
Del 1-2: 3
Volym 1: 3
Volym 2: 3
Särtryck: Nordforsk, Miljövårdssekretariatet publikation 1978:2: 2
Del 1: 2
Fotobilaga: 2
Kartbilaga: 2
Papperskopior: 2
Franska: 2
Bilagor, 10 st.: 1
vol. I: 1
Del I, III: 1
Vol. 1  A-H: 1
Med rätt titel och ISBN på bakre omslaget.: 1
vol. II: 1
Register: 1
2007: 1
Äldre upplaga.: 1
Vol. 2 I-Z: 1
Artikel i Environmental research 17,19-204(1978): 1
Artikel i Marine pollution bulletin, Vol. 9, 238-241(1978): 1
Obs defekt i bindning omslag och inlaga: 1
----------------------------------------- 9 -------------------------------------
12 Geovetenskaper: 1
071-SNV Rapport 4403: 1
071-SNV PM 1297: 1
----------------------------------------- 2 -------------------------------------
NVPUB: 19817
MON: 1817
----------------------------------------- 7 -------------------------------------
Fotobilaga.: 2
Kartbilaga.: 2
Endast personallån. Står på Miljöövervakningsenheten Mm.: 1
----------------------------------------- B -------------------------------------
NV:s publikationer: 19817
Monografier: 1817
----------------------------------------- p -------------------------------------
OI: 2
MI: 2
----------------------------------------- A -------------------------------------
Stockholm: 21917
----------------------------------------- 3 -------------------------------------
SNV-mon Monografier från Naturvårdsverket: 1219
071-SNV Naturvårdsverket informerar: 700
12 Geovetenskaper: 498
025 Samhällsvetenskap: 370
SNV-mon: 267
025.2 Ekonomi: 210
026 Administration och personalvård: 191
071-SNV Branschfakta: 168
021 Konventioner och internationell rätt: 130
071-SNV Rapporter / Statens naturvårdsverk: 106
071-SNV SEPA informs: 85
020.2 Svensk rätt: 71
071-SNV Naturvårdsverket informerar: Kemiska ämnen: 67
...
----------------------------------------- g -------------------------------------
1363: 2
1130: 2
1333: 1
2050: 1
2284: 1
1397: 1
2101: 1
2252: 1
1912: 1
821: 1
902: 1
    ...
----------------------------------------- 1 -------------------------------------
NVVST: 21917
----------------------------------------- M -------------------------------------
000: 18898
001: 1708
002: 653
003: 281
004: 142
005: 91
006: 48
007: 36
008: 16
009: 12
011: 9
010: 7
015: 6
012: 2
021: 1
029: 1
018: 1
030: 1
023: 1
017: 1
014: 1
013: 1
=cut	    

	my @Ls = $field->subfield('L');
	my $f = MARC::Field->new(952, ' ', ' ',
				 'a' => 'NATURVARD',
				 'b' => 'NATURVARD'
	    );
	if (defined $field->subfield('m')) {
	    $f->add_subfields('3', $field->subfield('m'));
	}
	if (defined $field->subfield('5')) {
	    $f->add_subfields('p', $field->subfield('5'));
	}
	if (defined $field->subfield('5')) {
	    $f->add_subfields('a', $field->subfield('5'));
	}
	if (defined $field->subfield('B')) {
	    $f->add_subfields('o', $field->subfield('B'));
	}
	if (defined $field->subfield('8')) {
	    $f->add_subfields('d', $field->subfield('8'));
	}

	if (defined $field->subfield('F')) {
	    my $itype_src = $field->subfield('F');
	    my $itype;
	    if ($itype_src eq 'Normallån') {
		$itype = 'NORMAL';
	    } elsif ($itype_src eq 'Referenslån') {
		$itype = 'REFERENS';
	    } elsif ($itype_src eq 'Personallån') {
		$itype = 'PERSONAL';
	    } elsif ($itype_src eq 'Tidskriftslån') {
		$itype = 'TIDSKRIFT';
	    } else {
		die "Unknown itype: $itype_src";
	    }
	    $f->add_subfields('y', $itype);
	}

	if (defined $field->subfield('h')) {
	    add_to_comment($f, $field->subfield('h'));
	}
	if (defined $field->subfield('4')) {
	    add_to_comment($f, $field->subfield('4'));
	}
	if (defined $field->subfield('7')) {
	    add_to_comment($f, $field->subfield('7'));
	}
	if (defined $field->subfield('P')) {
	    my $status = $field->subfield('P');
	    if ($status eq 'Saknas') {
		$f->add_subfields('1', 1);
	    } elsif ($status eq 'Order påbörja') {
		$f->add_subfields('7', -1);
	    }
	}
	if (defined $field->subfield('3')) {
	    $f->add_subfields('8', $field->subfield('3'));
	} elsif (defined $field->subfield('9')) {
	    $f->add_subfields('8', $field->subfield('9'));
	}


	push @items, $f;
    }

    $record->add_fields(@items);

    return $record;
}

sub _getline_aleph {
    my $self = shift;
    my $fh = shift;

    my $line = <$fh>;

    return undef unless defined $line;

    my $id = substr($line, 0, 9);
    my $cmd = substr($line, 10, 5);
    my $data = substr($line, 18);

    chomp $data;

    my $tag = '';
    my $ind1 = '';
    my $ind2 = '';

    if ($cmd eq 'LDR  ') {
	$tag = '000';
    } elsif ($cmd =~ /(0(?:(?:0[1-9])|(?:10)))(.)(.)/) {
	$tag = $1;
	$ind1 = $2;
	$ind2 = $3;
	$data =~ s/\^/ /g;
    } elsif ($cmd =~ /(\d\d\d)(.)(.)/) {
	$tag = $1;
	$ind1 = $2;
	$ind2 = $3;
    } elsif ($cmd =~ /Z30-1/) {
	$tag = '952';
	$ind1 = ' ';
	$ind2 = ' ';
    } else {
	unless ($self->{unknown}->{$cmd}) {
	    $self->{unknown}->{$cmd} = 1;
	    warn "Unknown command '$cmd'";
	}
    }

    return [$id, $tag, $ind1, $ind2, $data];
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
    my $columns = $self->getline( $fh );

    unless (defined($columns)) {
        if ($self->opt->format ne 'aleph' && (!$self->csv->eof && !$self->csv->status)) {
            croak "Error when reading input: " . $self->csv->error_diag;
        }
        $self->{eof} = 1;
        $self->{completed_record} = $self->{record_nr};
        $self->{record_nr} = undef;
        return undef;
    }

    my @col = @$columns;

    if ($self->opt->format ne 'micromarc' && $self->opt->format ne 'aleph') {
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

    } elsif ($self->opt->format eq 'aleph') {
	$field = {
	    record_nr  => $col[0],
	    field_type => $col[1],
	    indicator1 => $col[2],
	    indicator2 => $col[3],
	    content    => $col[4]
	};
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

