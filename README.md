# NAME

`Parallel::Prefork::IPC` - `Parallel::Prefork` with callbacks

# SYNOPSIS

    use Parallel::Prefork::IPC ;

    use feature qw(signatures) ;
    no warnings qw(experimental::signatures) ;

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

    my $DBH ;

    while ( $ppi->signal_received !~ /^(TERM|INT)$/ ) {

        # Sending a USR1 to the parent process, or calling $ppi->signal_received
        # (note: with no args) in the parent, will cause the connection to be renewed,
        # potentially with a new config. DB handles are not reliable across forks,
        # so the idea is to only use this object in the parent, and any time a child
        # needs to speak to the database, that can be done through a callback.
        $DBH = connect_to_db() ;

        $ppi->start and next ;

        # in child

        my $username = $ppi->callback('get_username') ;
        chomp $username ;

        if ( !$username ) {
            warn "No username received" ;
            $ppi->finish ;
            }

        $ppi->callback( log_child_event => { name => 'got username', note => $username } ) ;

        my $data = do_work_with($username) ;

        $ppi->callback( log_child_event => { name => 'finished work', note => $username } ) ;

        my $exit = $data ? 0 : 1 ;

        $ppi->finish( $exit, { username => $username, data => $data } ) ;
        }


    sub get_username ( $ppi, $kidpid ) {
        return get_next_username_from_database($DBH) ;
        }


    sub log_child_event ( $ppi, $kidpid, $event ) {
        warn sprintf "Child $kidpid event: %s (%s)\n", $event->{name}, $event->{note} ;
        }


    sub worker_finished ( $ppi, $kidpid, $status, $final_payload ) {
        if ( $status == 0 ) {
            my $username = $final_payload->{username} ;
            my $userdata = $final_payload->{data} ;
            store_somewhere( $DBH, $username => $userdata ) ;
            }
        else {
            warn "Problem with $kidpid (exit: $status) - got payload: " . Dumper($final_payload) ;
            }
        }

## Callbacks

The `callbacks` accessor holds a hashref mapping callback method names to coderefs:

    {
        $method_name => $coderef,
        ...
    }

Coderefs are called with the parent object, the child PID and the payload sent from the child:

    $coderef->($self, $kidpid, $payload) ;

In the child, callbacks are called thusly:

    $self->callback( $method_name => $payload ) ;

Empty/missing payloads are fine:

    $self->callback( $method_name ) ;

`$payload` can be a string, or a reference. The payload will be encoded as JSON
before sending, and decoded from JSON in the parent.

## RATIONALE

Does Perl really need yet another parallel process manager? I think so.

As far as I can see, all the available options have something going for them, but
none seem to have everything.

Parallel::ForkManager is great, but doesn't offer graceful shutdown, reloading
config, or a callback mechanism/IPC.

Parallel::PreFork offers graceful signal handling and reloadable config, but doesn't
return data from children, is awkward to supply job-specific arguments to each child,
and has no IPC.

Proc::Fork is lovely, and I stole the IPC from there, but you'd have to roll your own
multi-process management on top of it.

Parallel::Loops is lovely, but no IPC.

Parallel::PreforkManager almost has it all, BUT you have to set up all the jobs
beforehand and then hand off to the main loop, you can't run it in a while()
loop and keep adding new jobs. I stole the callback mechanism from there.

Parallel::Runner has everything except an explicit callback mechanism. However, it
does have `iteration_callback` which can probably be used to build such a thing
easily enough. Also, although it does pass data back to the parent, you have to
handle serialization yourself for anything more than simple strings.

So, features of Parallel::Prefork::IPC (and where I stole the implementation from)

\- responds gracefully (and customizably) to signals                 \[Parallel::Prefork\]
\- can reload config data                                            \[Parallel::Prefork\]
\- configurable max children                                         \[Parallel::Prefork\]
\- timeout on final wait\_all\_children                                \[Parallel::Prefork\]
\- timeout on individual children                                    left for users to write according to their own needs, Time::Out is very handy
\- callback mechanism                                                \[Parallel::PreforkManager\]
\- passing final data payload back to parent                         several libraries do this, the implementation used here is built on top of the callback mechanism
\- IPC                                                               \[Proc::Fork\] - a pair of pipes shared between each child and the parent. The details
                                                                        are wrapped in the callback mechanism.
\- ability to add jobs to the queue while the main loop is running   \[Parallel::Prefork\]
