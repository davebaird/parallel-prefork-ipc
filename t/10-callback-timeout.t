use strict ;
use warnings ;

use v5.10 ;    # for state

use Test::More ;
use Test::SharedFork ;
use Test::Fatal ;
use Feature::Compat::Try ;
use Parallel::Prefork::IPC ;

my $i ;

my $pm = Parallel::Prefork::IPC->new(
    {   max_workers  => 3,
        trap_signals => { TERM => 'TERM', },

        callbacks => {
            long_cb => sub {
                sleep 20 ;
            },

            },

        callback_timeout => 1,

        before_fork => sub {
            $i++ ;
        },
        }
    ) ;

while ( $pm->signal_received ne 'TERM' ) {
    $pm->start and next ;

    $pm->finish(0) if $i > 2 ;

    if ( $i == 2 ) {
        sleep 2 ;
        kill( TERM => $pm->manager_pid ) ;
        }

    like( exception { $pm->callback('long_cb') }, qr/timeout at /, 'caught timeout error' ) ;

    cmp_ok( $i, '==', 1, 'only the first child gets here' ) ;

    $pm->finish(0) ;
    }

$pm->wait_all_children ;

cmp_ok( $i, '>=', 3, 'before_fork callback was called 3 times or more' ) ;

done_testing ;
