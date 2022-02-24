package Parallel::Prefork::IPC ;

use v5.24 ;    # for postfix dereferencing etc.

use strict ;
use warnings ;
use Carp ;
use Data::Dumper ;

use IO::Pipe ;
use Feature::Compat::Try ;
use JSON ;
use Time::Out qw(timeout) ;

use constant BLOCK => 1 ;

use base 'Parallel::Prefork' ;

__PACKAGE__->mk_accessors(qw/callbacks callback_timeout/) ;

use feature qw(signatures) ;

no warnings qw(experimental::signatures) ;

=pod

=head1 NAME

C<Parallel::Prefork::IPC> - C<Parallel::Prefork> with callbacks

=head1 SYNOPSIS

    use Parallel::Prefork::IPC ;

    use Data::Dumper ;
    use feature qw(signatures) ;
    no warnings qw(experimental::signatures) ;

    my $CFG ;
    my $TIMEOUT       = 30 ;
    my $GOT_USERNAMES = 1 ;
    my $E_OK          = 0 ;
    my $E_NO_USERNAME = 5 ;
    my $E_NO_DATA     = 6 ;


    my $ppi = Parallel::Prefork::IPC->new(
        {   max_workers => 5,

            on_child_reap => \&worker_finished,

            callbacks => {
                get_username    => \&get_username,
                log_child_event => \&log_child_event,
                },

            callback_timeout => 10,

            trap_signals => {
                TERM => 'TERM',
                HUP  => 'TERM',
                INT  => 'INT',
                USR1 => undef,
                }
                }
        ) ;

    while ( $GOT_USERNAMES and $ppi->signal_received !~ /^(TERM|INT)$/ ) {

        # Note: this while() loop does NOT cycle for every child, so don't be
        #       tempted to set up per-child init data here. The before_fork()
        #       hook might be useful, or else a callback from the child,
        #       as shown here.

        # Note: for jobs processing (as opposed to server instances) bear in
        #       mind that more kids than necessary are likely to be
        #       started, so each kid should check it has received appropriate
        #       initialisation data and if not, call finish() or return.

        $CFG = get_config() ;

        $ppi->start and next ;

        # in child

        my $username = $ppi->callback('get_username') ;

        $ppi->finish($E_NO_USERNAME) unless $username ;

        $ppi->callback( log_child_event => { name => 'got username', note => $username } ) ;

        my $data = do_work_with($username) ;

        $ppi->callback( log_child_event => { name => 'finished work', note => $username } ) ;

        my $exit = $data ? $E_OK : $E_NO_DATA ;

        $ppi->finish( $exit, { username => $username, data => $data } ) ;
        }

    $ppi->wait_all_children( $TIMEOUT ) ;


    sub get_username ( $ppi, $kidpid ) {
        my $un = get_next_username_from_somewhere() ;
        $GOT_USERNAMES = 0 unless $un ;
        return $un ;
        }


    sub log_child_event ( $ppi, $kidpid, $event ) {
        warn sprintf "Child $kidpid event: %s (%s)\n", $event->{name}, $event->{note} ;
        }


    sub worker_finished ( $ppi, $kidpid, $status, $final_payload ) {
        if ( $status == $E_OK ) {
            my $username = $final_payload->{username} ;
            my $userdata = $final_payload->{data} ;
            store_somewhere( $username => $userdata ) ;
            }
        elsif ( $status == $E_NO_USERNAME ) {
            warn "Child $kidpid: no username received" ;
            }
        elsif ( $status == $E_NO_DATA ) {
            warn "Child $kidpid: no data retrieved for " . $final_payload->{username} ;
            }
        else {
            warn "Child $kidpid: unexpected problem (exit: $status) - got payload: " . Dumper($final_payload) ;
            }
        }

=head1 DESCRIPTION

Inherits from C<Parallel::Prefork>. The docs here focus on the additional IPC/callbacks features.

=head1 IPC

Bi-directional communication between each child and the parent process is implemented via
a pair of pipes. This is all wrapped in the callback mechanism, so the main thing to
be aware of is that all messages are serialized/deserialized as JSON strings before
being sent across the pipe.

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

C<$payload> can be not present at all, undef, a string or number, or a reference.
The payload will be encoded as JSON before sending, and decoded from JSON in the parent.
Ditto for any data sent back to the child.

=head3 C<callback_timeout>

You can optionally specify a timeout (in seconds) for callbacks. Default is no timeout.

=head2 RATIONALE

Does Perl really need yet another parallel process manager? I think so.

As far as I can see, all the available options have something going for them, but
none seem to have everything.

C<Parallel::ForkManager> is great, but doesn't offer graceful signal handling, reloading
config, or a callback mechanism. It does return a data structure from each child,
via a file, using C<Storable> for serializing. That works fine even if it feels
a little clunky. IMHO.

C<Parallel::PreFork> offers graceful signal handling and reloadable config, but doesn't
return data from children, is a little awkward to supply job-specific arguments to each child
(you set variables up in the parent in the C<before_fork> hook), and has no IPC.

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
but I haven't got my head round that stuff yet.

Basically, C<Parallel::ForkManager> and C<Parallel::Prefork> supported all my
needs, until I needed callbacks.

=head2 FEATURES

(and where I stole the implementation from):

=over 4

=item Responds gracefully (and customizably) to signals

C<Parallel::Prefork>

=item Can reload config data

C<Parallel::Prefork>

=item Configurable max children

C<Parallel::Prefork>

=item Timeout on final C<wait_all_children>

C<Parallel::Prefork>

=item Timeout on individual children

Left for users to write according to their own needs, C<Time::Out> is very handy

=item Callback mechanism

C<Parallel::PreforkManager>

=item Pass final data payload back to parent

Several packages do this, the implementation used here is built on top of the callback mechanism

=item IPC

C<Proc::Fork> - a pair of pipes shared between each child and the parent. The details are wrapped in the callback mechanism.

=item Ability to add jobs to the queue while the main loop is running

C<Parallel::Prefork>


=back

=head3 Read more

Apart from the docs for C<Parallel::Prefork>, there's a useful blog here: https://perl-users.jp/articles/advent-calendar/2010/english/4

=cut


sub new {
    my $proto = shift ;
    my $self  = $proto->SUPER::new(@_) ;

    # create new pair of pipes before each fork
    my $before_fork_orig_cb = $self->before_fork ;
    $self->before_fork(
        sub {
            my ($self) = @_ ;
            $self->{_temp_store_pipes} = { p2c => IO::Pipe->new, c2p => IO::Pipe->new } ;
            $before_fork_orig_cb && $before_fork_orig_cb->($self) ;
            }
            ) ;

    # set up pipes in parent
    my $after_fork_orig_cb = $self->after_fork ;
    $self->after_fork(
        sub {
            my ( $self, $kidpid ) = @_ ;
            my $pipes = delete $self->{_temp_store_pipes} ;
            $pipes->{p2c}->writer ;
            $pipes->{c2p}->reader ;
            $self->{ipc}->{$kidpid}->{pipes} = $pipes ;
            $after_fork_orig_cb && $after_fork_orig_cb->( $self, $kidpid ) ;
            }
            ) ;

    # setup the __finish__ callback
    $self->callbacks( {} ) unless $self->callbacks ;
    $self->callbacks->{__finish__} = sub {
        my ( $self, $kidpid, $child_payload ) = @_ ;
        $self->{ipc}->{$kidpid}->{final_payload} = $child_payload ;    # this will be picked up in _on_child_reap()
        } ;

    # call _handle_callbacks by piggy-backing on __dbg_callback
    my $dbg_orig_cb = $self->{__dbg_callback} ;
    $self->{__dbg_callback} = sub {
        $self->_handle_callbacks ;
        $dbg_orig_cb && $dbg_orig_cb->() ;
        } ;

    $self ;
    }

# set up pipes in child before running child code - yes, this is an ugly hack,
# piggy-backing on this method simply bc it's called in the right place
sub signal_received ( $self, @args ) {
    if ( $self->{in_child} ) {
        if ( my $pipes = delete $self->{_temp_store_pipes} ) {
            $pipes->{p2c}->reader ;
            $pipes->{c2p}->writer ;
            $self->{ipc}->{$$}->{pipes} = $pipes ;
            }
        }

    $self->SUPER::signal_received(@args) ;
    }


sub finish ( $self, $exit_code = undef, $final_payload = undef ) {
    $self->callback( '__finish__', $final_payload ) if $final_payload ;    # blocks until we get back an empty reply
    $self->SUPER::finish($exit_code) ;
    }


sub _on_child_reap ( $self, $exit_pid, $status ) {
    my $final_payload = $self->{ipc}->{$exit_pid}->{final_payload} ;
    delete $self->{ipc}->{$exit_pid} ;

    if ( my $cb = $self->on_child_reap ) {
        eval { $cb->( $self, $exit_pid, $status, $final_payload )  } ;
        warn "Error processing on_child_reap() callback for child $exit_pid: $@" if $@ ;
        }
    }

# in parent
sub _handle_callbacks ($self) {
    foreach my $kidpid ( keys $self->{worker_pids}->%* ) {
        my $message = $self->_receive($kidpid) || next ;

        # warn "_handle_callbacks: received message:" . Dumper($message) ;

        my $parent_payload ;
        my $msg = {} ;

        try {
            $msg->{parent_payload} = $self->_handle_callback( $kidpid, $message ) ;
            }
        catch ($e) {
            $msg->{error} = $e ;
            # warn "Caught error handling callback for child $kidpid: $e" ;
            }

        # always send something (even undef) back bc child is blocked until receives reply
        $self->_send( $msg, $kidpid ) ;
        }
    }

# in parent
sub _handle_callback ( $self, $kidpid, $message ) {
    my $cb_name = $message->{callback_method} ;

    my $cb = $self->callbacks->{$cb_name}
        || die "Unknown callback method '$cb_name' called by $kidpid: DATA: " . Dumper($message) ;

    my $parent_payload ;

    if ( my $timeout = $self->callback_timeout ) {
        $parent_payload = timeout $timeout => sub { $cb->( $self, $kidpid, $message->{child_payload} )  } ;
        die $@ if $@ ;
        }
    else {
        $parent_payload = $cb->( $self, $kidpid, $message->{child_payload} ) ;
        }

    return $parent_payload ;
    }

# in child
sub callback ( $self, $method, $data = undef ) {
    $self->{in_child} || croak "callback('$method') only available in child" ;

    $self->_send(
        {   'callback_method' => $method,
            'child_payload'   => $data,
            }
        ) ;

    my $reply = $self->_receive( $$, BLOCK ) ;

    croak "Callback error: " . $reply->{error} if $reply->{error} ;

    return $reply->{parent_payload} if $reply ;    # if manager is killed some kids will not get a reply

    return ;
    }


sub _send ( $self, $hashref, $kidpid = $$ ) {
    !$self->{in_child} and $kidpid == $$ and croak "Must supply target worker PID when sending from parent" ;

    my $pc = $self->{in_child} ? ' child' : 'parent' ;

    # warn "$$ $pc: sending: " . Dumper($hashref) ;

    my $pipe
        = $self->{in_child}
        ? $self->{ipc}->{$kidpid}->{pipes}->{c2p}
        : $self->{ipc}->{$kidpid}->{pipes}->{p2c} ;

    $hashref->{kidpid} = $kidpid ;

    my $encoded = encode_json($hashref) ;

    $pipe->say($encoded) ;
    $pipe->flush ;
    return ;
    }


sub _receive ( $self, $kidpid = $$, $block = 0 ) {
    !$self->{in_child} and $kidpid == $$ and croak "Must supply target worker PID when receiving in parent" ;

    my $pipe
        = $self->{in_child}
        ? $self->{ipc}->{$kidpid}->{pipes}->{p2c}
        : $self->{ipc}->{$kidpid}->{pipes}->{c2p} ;

    my ($line) = $block ? ( $pipe->getline ) : _read_lines_nb($pipe) ;

    chomp($line) if $line ;

    return unless $line ;

    # warn "Received: $line" ;

    my $message = eval { decode_json($line)  } ;
    warn "Error decoding line: $@" if $@ ;

    return $message ;
    }


sub _read_lines_nb ($fh) {
    state %nonblockGetLines_last ;

    my $timeout = 0 ;
    my $rfd     = '' ;
    $nonblockGetLines_last{$fh} = ''
        unless defined $nonblockGetLines_last{$fh} ;

    vec( $rfd, fileno($fh), 1 ) = 1 ;
    return unless select( $rfd, undef, undef, $timeout ) >= 0 ;
    return unless vec( $rfd, fileno($fh), 1 ) ;

    my $buf = '' ;
    my $n   = sysread( $fh, $buf, 1024 * 1024 ) ;

    # If we're done, make sure to send the last unfinished line
    # return ( 1, $nonblockGetLines_last{$fh} ) unless $n ;
    return $nonblockGetLines_last{$fh} unless $n ;

    # Prepend the last unfinished line
    $buf = $nonblockGetLines_last{$fh} . $buf ;

    # And save any newly unfinished lines
    $nonblockGetLines_last{$fh} = ( substr( $buf, -1 ) !~ /[\r\n]/ && $buf =~ s/([^\r\n]*)$// ) ? $1 : '' ;

    # $buf ? ( 0, split( /\n/, $buf ) ) : (0) ;
    return split( /\n/, $buf ) if $buf ;
    return ;
    }

1 ;
