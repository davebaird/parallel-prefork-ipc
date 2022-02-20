package Parallel::Prefork::IPC ;

use v5.24 ;    # for postfix dereferencing etc.

use strict ;
use warnings ;
use Carp ;

use IO::Pipe ;
use Feature::Compat::Try ;
use JSON ;

use base 'Parallel::Prefork' ;

use Class::Accessor::Lite ( rw => [qw/callbacks/] ) ;

use feature qw(signatures) ;

no warnings qw(experimental::signatures) ;

=pod

=head1 NAME

C<Parallel::Prefork::IPC> - C<Parallel::Prefork> with callbacks

=head1 SYNOPSIS

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

=head1 DESCRIPTION

Inherits from C<Parallel::Prefork>. The docs here focus on the additional IPC/callbacks features.

=head1 IPC

Bi-directional communication between each child and the parent process is implemented via
a pair of pipes. This is wrapped in the callback mechanism, so the main thing to
be aware of is that all messages are serialized/deserialized as JSON strings.
Any data you send must be a single scalar (number, string, or reference) and must be
serializable to JSON.

=head2 Callbacks

The C<callbacks> accessor holds a hashref mapping callback method names to coderefs:

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

C<$payload> can be a string, or a reference. The payload will be encoded as JSON
before sending, and decoded from JSON in the parent.

=head2 RATIONALE

Does Perl really need yet another parallel process manager? I think so.

As far as I can see, all the available options have something going for them, but
none seem to have everything.

C<Parallel::ForkManager> is great, but doesn't offer graceful signal handling, reloading
config, or a callback mechanism (although it does return a data structure from each child).

C<Parallel::PreFork> offers graceful signal handling and reloadable config, but doesn't
return data from children, is awkward to supply job-specific arguments to each child,
and has no IPC.

C<Proc::Fork> is lovely, and I stole the IPC from there, but you'd have to roll your own
multi-process management on top of it.

C<Parallel::Loops> is also lovely, accepts per-child initialisation data,
returns final output to the parent, but no callbacks.

C<Parallel::PreforkManager> almost has it all, BUT you have to set up all the jobs
beforehand and then hand off to the main loop, AFAIK you can't run it in a while()
loop and keep adding new jobs. I stole the callback mechanism from there.

C<Parallel::Runner> has everything except an explicit callback mechanism. However, it
does have C<iteration_callback> which can probably be used to build such a thing
easily enough. Although it does pass final data back to the parent, you have to
handle serialization yourself for anything more than simple strings.

There are other options on CPAN as well, especially in the world of async programming,
but I haven't got my head round that world yet.

Basically, C<Parallel::ForkManager> and C<Parallel::Prefork> supported all my
needs, until I needed callbacks.

=head3 Features of C<Parallel::Prefork::IPC>

(and where I stole the implementation from):

=over 4

=item responds gracefully (and customizably) to signals     [Parallel::Prefork]

=item can reload config data                                [Parallel::Prefork]

=item configurable max children                             [Parallel::Prefork]

=item timeout on final wait_all_children                    [Parallel::Prefork]

=item timeout on individual children                        left for users to write according to their own needs, Time::Out is very handy

=item callback mechanism                                    [Parallel::PreforkManager]

=item passing final data payload back to parent             several libraries do this, the implementation used here is built on top of the callback mechanism

=item IPC                                                   [Proc::Fork] - a pair of pipes shared between each child and the parent. The details are wrapped in the callback mechanism.

=item ability to add jobs to the queue while the main loop is running      [Parallel::Prefork]


=back

=cut

# in parent
sub _handle_callbacks ($self) {
KID:
    foreach my $kidpid ( keys $self->{worker_pids}->%* ) {
        try {
            my $message = $self->_receive($kidpid) ;
            next KID unless $message ;

            if ( $message->{method} eq 'callback' ) {
                my $parent_payload
                    = $self->callbacks->{ $message->{callback_method} }->( $self, $kidpid, $message->{child_payload} ) ;
                $self->_send( { parent_payload => $parent_payload }, $kidpid ) ;
                }
            elsif ( $message->{method} eq '__finish__' ) {
                $self->{worker_pids}->{$kidpid}->{final_payload} = $message->{payload} ;
                $self->_send( {}, $kidpid ) ;    # child is blocked in finish() until it hears back from us
                }
            else {
                die sprintf "Unknown callback type '%s' sent by kid $kidpid", $message->{method} ;
                }
            }

        catch ($e) {
            warn "Ignoring error handling callback for child $kidpid: $e" ;
            }
        }
    }

# in child
sub callback ( $self, $method, $data = {} ) {
    $self->{in_child} || croak "callback('$method') only available in child" ;

    $self->_send(
        {   'method'          => 'callback',
            'callback_method' => $method,
            'child_payload'   => $data,
            }
        ) ;

    $self->_receive->{parent_payload} ;    # parent_payload doesn't exist in response from __finish__ callback, that's ok
    }


sub _send ( $self, $hashref, $kidpid = $$ ) {
    !$self->{in_child} and $kidpid == $$ and croak "Must supply target worker PID when sending from parent" ;

    my $pipe
        = $self->{in_child}
        ? $self->{worker_pids}->{$kidpid}->{pipes}->{c2p}
        : $self->{worker_pids}->{$kidpid}->{pipes}->{p2c} ;

    $hashref->{kidpid} = $kidpid ;

    my $encoded = encode_json($hashref) ;
    $pipe->print("$encoded\n") ;

    $pipe->flush ;
    return ;
    }


sub _receive ( $self, $kidpid = $$ ) {
    !$self->{in_child} and $kidpid == $$ and croak "Must supply target worker PID when receiving in parent" ;

    my $pipe
        = $self->{in_child}
        ? $self->{worker_pids}->{$kidpid}->{pipes}->{p2c}
        : $self->{worker_pids}->{$kidpid}->{pipes}->{c2p} ;

    my $line = $pipe->getline ;

    return unless $line ;

    chomp $line ;

    my $message = eval { decode_json($line)  } ;

    return $message ;
    }

# modified from P::PF
sub start ( $self, $cb ) {
    $self->manager_pid($$) ;
    $self->signal_received('') ;
    $self->{generation}++ ;

    die 'cannot start another process while you are in child process'
        if $self->{in_child} ;

    # main loop
    while ( !$self->signal_received ) {
        my $action = $self->{_no_adjust_until} <= Time::HiRes::time()
            && $self->_decide_action ;
        if ( $action > 0 ) {

            # start a new worker
            if ( my $subref = $self->before_fork ) {
                $subref->($self) ;
                }

            my $pipe_p2c = IO::Pipe->new ;
            my $pipe_c2p = IO::Pipe->new ;

            my $pid = fork ;

            unless ( defined $pid ) {
                warn "fork failed:$!" ;
                $self->_update_spawn_delay( $self->err_respawn_interval ) ;
                next ;
                }

            unless ($pid) {

                # child process
                $pipe_p2c->reader ;
                $pipe_c2p->writer ;
                $self->{worker_pids}->{$$}->{pipes}->{p2c} = $pipe_p2c ;
                $self->{worker_pids}->{$$}->{pipes}->{c2p} = $pipe_c2p ;

                $self->{in_child} = 1 ;
                $SIG{$_}          = 'DEFAULT' for keys %{ $self->trap_signals } ;
                $SIG{CHLD}        = 'DEFAULT' ;                                     # revert to original
                exit 0 if $self->signal_received ;
                if ($cb) {
                    $cb->() ;
                    $self->finish() ;
                    }
                return ;
                }

            # back in parent
            $pipe_p2c->writer ;
            $pipe_c2p->reader ;
            $self->{worker_pids}->{$pid}->{pipes}->{p2c} = $pipe_p2c ;
            $self->{worker_pids}->{$pid}->{pipes}->{c2p} = $pipe_c2p ;

            if ( my $subref = $self->after_fork ) {
                $subref->( $self, $pid ) ;
                }

            $self->{worker_pids}{$pid}{generation} = $self->{generation} ;
            $self->_update_spawn_delay( $self->spawn_interval ) ;
            }
        elsif ( $action < 0 ) {

            # stop an existing worker
            kill( $self->_action_for('TERM')->[0], ( keys %{ $self->{worker_pids} } )[0], ) ;
            $self->_update_spawn_delay( $self->spawn_interval ) ;
            }

        $self->{__dbg_callback}->() if $self->{__dbg_callback} ;

        $self->_handle_callbacks ;

        if ( my ( $exit_pid, $status ) = $self->_wait( !$self->{__dbg_callback} && $action <= 0 ) ) {
            $self->_on_child_reap( $exit_pid, $status, $self->{worker_pids}{$exit_pid}{final_payload} ) ;
            if ( $self->{worker_pids}{$exit_pid}{generation} == $self->{generation} and $status != 0 ) {
                delete( $self->{worker_pids}{$exit_pid} ) ;
                $self->_update_spawn_delay( $self->err_respawn_interval ) ;
                }
            }
        }

    # send signals to workers
    if ( my $action = $self->_action_for( $self->signal_received ) ) {
        my ( $sig, $interval ) = @$action ;
        if ($interval) {

            # fortunately we are the only one using delayed_task, so implement
            # this setup code idempotent and replace the already-registered
            # callback (if any)
            my @pids = sort keys %{ $self->{worker_pids} } ;
            $self->{delayed_task} = sub {
                my $self = shift ;
                my $pid  = shift @pids ;
                kill $sig, $pid ;
                if ( @pids == 0 ) {
                    delete $self->{delayed_task} ;
                    delete $self->{delayed_task_at} ;
                    }
                else {
                    $self->{delayed_task_at} = Time::HiRes::time() + $interval ;
                    }
                } ;
            $self->{delayed_task_at} = 0 ;
            $self->{delayed_task}->($self) ;
            }
        else {
            $self->signal_all_children($sig) ;
            }
        }

    1 ;    # return from parent process
    }

# modified from P::PF
sub finish ( $self, $exit_code, $final_payload ) {
    die "\$parallel_prefork->finish() shouln't be called within the manager process\n"
        if $self->manager_pid() == $$ ;
    $self->callback( '__finish__', $final_payload ) ;    # blocks until we get back an empty reply
    exit( $exit_code || 0 ) ;
    }

# modified from P::PF
sub _on_child_reap {
    my ( $self, $exit_pid, $status, $final_payload ) = @_ ;
    my $cb = $self->on_child_reap ;
    if ($cb) {
        eval { $cb->( $self, $exit_pid, $status, $final_payload ) ; } ;

        # XXX - hmph, what to do here?
        warn "Error processing on_child_reap() callback: $@" if $@ ;
        }
    }

1 ;
