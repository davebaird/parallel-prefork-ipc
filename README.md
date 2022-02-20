# NAME

`Parallel::Prefork::IPC` - `Parallel::Prefork` with callbacks

# SYNOPSIS

    use Parallel::Prefork::IPC ;

    use feature qw(signatures) ;
    no warnings qw(experimental::signatures) ;

    my $DBH ;
    my $E_OK          = 0 ;
    my $E_GENERIC     = 1 ;
    my $E_NO_USERNAME = 5 ;
    my $E_NO_DATA     = 6 ;


    my $ppi = Parallel::Prefork::IPC->new(
        {   max_workers => 5,

            on_child_reap => \&worker_finished,

            callbacks => {
                get_username    => \&get_username,
                log_child_event => \&log_child_event,
                },

            trap_signals => {
                TERM => 'TERM',
                HUP  => 'TERM',
                INT  => 'INT',
                USR1 => undef,
                }
                }
        ) ;

    while ( $ppi->signal_received !~ /^(TERM|INT)$/ ) {

        # Sending a USR1 to the parent process, or calling $ppi->signal_received
        # (note: with no args) in the parent, will cause the connection to be renewed,
        # potentially with a new config. DB handles are not reliable across forks,
        # so the idea is to only use this object in the parent, and any time a child
        # needs to speak to the database, that can be done through a callback.
        $DBH = connect_to_db() ;

        $ppi->start and next ;

        # in child

        undef $DBH ;    # just in case

        my $username = $ppi->callback('get_username') ;
        chomp $username ;

        if ( !$username ) {
            warn "No username received" ;
            $ppi->finish($E_NO_USERNAME) ;
            }

        $ppi->callback( log_child_event => { name => 'got username', note => $username } ) ;

        my $data = do_work_with($username) ;

        $ppi->callback( log_child_event => { name => 'finished work', note => $username } ) ;

        my $exit = $data ? $E_OK : $E_NO_DATA ;

        $ppi->finish( $exit, { username => $username, data => $data } ) ;
        }


    sub get_username ( $ppi, $kidpid ) {
        return get_next_username_from_database($DBH) ;
        }


    sub log_child_event ( $ppi, $kidpid, $event ) {
        warn sprintf "Child $kidpid event: %s (%s)\n", $event->{name}, $event->{note} ;
        }


    sub worker_finished ( $ppi, $kidpid, $status, $final_payload ) {
        if ( $status == $E_OK ) {
            my $username = $final_payload->{username} ;
            my $userdata = $final_payload->{data} ;
            store_somewhere( $DBH, $username => $userdata ) ;
            }
        elsif ( $status == $E_NO_USERNAME ) {
            warn "Child $kidpid: no username found" ;
            }
        elsif ( $status == $E_NO_DATA ) {
            warn "Child $kidpid: No data retrieved for " . $final_payload->{username} ;
            }
        else {
            warn "Child $kidpid: unexpected problem (exit: $status) - got payload: " . Dumper($final_payload) ;
            }
        }

# DESCRIPTION

Inherits from `Parallel::Prefork`. The docs here focus on the additional IPC/callbacks features.

# IPC

Bi-directional communication between each child and the parent process is implemented via
a pair of pipes. This is wrapped in the callback mechanism, so the main thing to
be aware of is that all messages are serialized/deserialized as JSON strings.
Any data you send must be a single scalar (number, string, or reference) and must be
serializable to JSON.

## Callbacks

The `callbacks` accessor holds a hashref mapping callback method names to coderefs:

    {
        $method_name => $coderef,
        ...
    }

Callbacks are passed the parent object, the child PID and the payload sent from the child:

    $coderef->($ppi, $kidpid, $payload) ;

In the child, callbacks are called thusly:

    $ppi->callback( $method_name => $payload ) ;

Empty/missing payloads are fine:

    $ppi->callback( $method_name ) ;

`$payload` can be a string, or a reference. The payload will be encoded as JSON
before sending, and decoded from JSON in the parent.

## RATIONALE

Does Perl really need yet another parallel process manager? I think so.

As far as I can see, all the available options have something going for them, but
none seem to have everything.

`Parallel::ForkManager` is great, but doesn't offer graceful signal handling, reloading
config, or a callback mechanism (although it does return a data structure from each child).

`Parallel::PreFork` offers graceful signal handling and reloadable config, but doesn't
return data from children, is awkward to supply job-specific arguments to each child,
and has no IPC.

`Proc::Fork` is lovely, and I stole the IPC from there, but you'd have to roll your own
multi-process management on top of it.

`Parallel::Loops` is also lovely, accepts per-child initialisation data,
returns final output to the parent, but no callbacks.

`Parallel::PreforkManager` almost has it all, BUT you have to set up all the jobs
beforehand and then hand off to the main loop, AFAIK you can't run it in a while()
loop and keep adding new jobs. I stole the callback mechanism from there.

`Parallel::Runner` has everything except an explicit callback mechanism. However, it
does have `iteration_callback` which can probably be used to build such a thing
easily enough. Although it does pass final data back to the parent, you have to
handle serialization yourself for anything more than simple strings.

There are other options on CPAN as well, especially in the world of async programming,
but I haven't got my head round that world yet.

Basically, `Parallel::ForkManager` and `Parallel::Prefork` supported all my
needs, until I needed callbacks.

### Features of `Parallel::Prefork::IPC`

(and where I stole the implementation from):

- responds gracefully (and customizably) to signals

    \[Parallel::Prefork\]

- can reload config data

    \[Parallel::Prefork\]

- configurable max children

    \[Parallel::Prefork\]

- timeout on final wait\_all\_children

    \[Parallel::Prefork\]

- timeout on individual children

    left for users to write according to their own needs, Time::Out is very handy

- callback mechanism

    \[Parallel::PreforkManager\]

- passing final data payload back to parent

    several libraries do this, the implementation used here is built on top of the callback mechanism

- IPC

    \[Proc::Fork\] - a pair of pipes shared between each child and the parent. The details are wrapped in the callback mechanism.

- ability to add jobs to the queue while the main loop is running

    \[Parallel::Prefork\]
