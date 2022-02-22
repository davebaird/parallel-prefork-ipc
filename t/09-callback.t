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

        callbacks => {
            add_payload => sub {
                my ( $self, $kidpid, $payload ) = @_ ;
                $sum += $payload ;
            },
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

    $pm->callback( 'add_payload', $payload ) ;

    $pm->finish(0) ;
    }

$pm->wait_all_children ;

cmp_ok( $i,   '>=', 10,  'before_fork callback was called 10 times or more' ) ;
cmp_ok( $sum, '==', 385, 'payloads were delivered' ) ;

done_testing ;
