use strict ;
use warnings ;

use Test::More ;
use Test::SharedFork ;
use Parallel::Prefork::IPC ;

my $sum = 0 ;
my $i   = 0 ;

my $pm = Parallel::Prefork::IPC->new(
    {   max_workers  => 3,
        trap_signals => { TERM => 'TERM', },

        on_child_reap => sub {
            my ( $pm, $kidpid, $status, $final_payload ) = @_ ;
            $sum += $final_payload if $final_payload ;    # the TERM will often kill a kid before it can call finish()
        },

        before_fork => sub {
            $i++ ;
        },
        }
    ) ;

while ( $pm->signal_received ne 'TERM' ) {
    $pm->start and next ;

    kill( TERM => $pm->manager_pid ) if $i == 11 ;    # the last payload ($i == 11) doesn't get through

    my $payload = $i > 10 ? 0 : $i**2 ;

    $pm->finish( 0, $payload ) ;
    }

$pm->wait_all_children ;

cmp_ok( $i,   '>=', 10,  'before_fork callback was called 10 times or more' ) ;
cmp_ok( $sum, '==', 385, 'payloads were delivered' ) ;

done_testing ;
