use strict ;
use warnings ;

use Test::More ;
use Test::SharedFork ;
use Parallel::Prefork::IPC ;

my ( $sum, $i, $empty, $undefs, $refs ) = ( 0, 0, 0, 0, {} ) ;

my $pm = Parallel::Prefork::IPC->new(
    {   max_workers  => 3,
        trap_signals => { TERM => 'TERM', },

        callbacks => {
            add_payload => sub {
                my ( $self, $kidpid, $payload ) = @_ ;
                $sum += $payload ;
            },
            empty_payload => sub {
                my ( $self, $kidpid, $payload ) = @_ ;
                die "Unexpected non-empty payload: $payload" if defined($payload) ;
                $empty++ ;
            },
            undef_payload => sub {
                my ( $self, $kidpid, $payload ) = @_ ;
                die "Unexpected undefined payload: $payload" if defined($payload) ;
                $undefs++ ;
            },
            ref_payload => sub {
                my ( $self, $kidpid, $payload ) = @_ ;
                $refs->{$_} = $payload->{$_} for keys $payload->%* ;
            },
            },

        before_fork => sub {
            $i++ ;
        },
        }
    ) ;

while ( $pm->signal_received ne 'TERM' ) {
    $pm->start and next ;

    if ( $i == 11 ) {
        sleep 1 ;                             # let the kids send their callbacks before shutting down
        kill( TERM => $pm->manager_pid ) ;    # the last payload ($i == 11) doesn't get through
        }

    if ( $i <= 10 ) {
        my $data_ref = { $i => { foo => 'bar', baz => undef, and => [ i => $i ] } } ;
        $pm->callback( 'add_payload', $i**2 ) ;
        $pm->callback('empty_payload') ;
        $pm->callback( 'undef_payload', undef ) ;
        $pm->callback( 'ref_payload',   $data_ref ) ;
        }

    $pm->finish(0) ;
    }

$pm->wait_all_children ;

cmp_ok( $i,      '>=', 10,  'before_fork callback was called 10 times or more' ) ;
cmp_ok( $sum,    '==', 385, 'payloads were delivered' ) ;
cmp_ok( $empty,  '==', 10,  '10 empty payloads' ) ;
cmp_ok( $undefs, '==', 10,  '10 undef payloads' ) ;

my %expected_refs = map { $_ => { foo => 'bar', baz => undef, and => [ i => $_ ] } } 1 .. 10 ;

is_deeply( $refs, \%expected_refs, "got expected ref payloads" ) ;

done_testing ;
