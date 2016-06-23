package ExplicitRecordNrField;

use strict;
use Readonly;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw();
@EXPORT_OK   = qw($RECORD_NR_FIELD $RECORD_NR_SUBFIELD);

# XXX We store the record id in the raw marcxml and have it removed before import.
Readonly::Scalar our $RECORD_NR_FIELD     =>'999';
Readonly::Scalar our $RECORD_NR_SUBFIELD  => 'a';

1;
