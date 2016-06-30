package ExplicitRecordNrField;

use strict;
use Readonly;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw();
@EXPORT_OK   = qw($RECORD_NR_FIELD $RECORD_NR_SUBFIELD);

# We store the record id in the raw marcxmlin the field 999 c.  This field should be same as in the bibliographic
# framework that maps biblio.biblionumber to a marc field in Koha.
#
# By preserving the Libra bibliographic record id, we can have bulkmarcimport.pl generate an idmap file which
# can be used for further processing the data.
Readonly::Scalar our $RECORD_NR_FIELD     =>'999';
Readonly::Scalar our $RECORD_NR_SUBFIELD  => 'c';

1;
