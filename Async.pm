=head1 NAME

EV::Loop::Async - run an EV event loop asynchronously

=head1 SYNOPSIS

  use EV::Loop::Async;
  
  my $loop = EV::Loop::Async::default;
  my $timer;
  my $flag;
  
  # create a watcher, but make sure the loop is locked
  {
     $loop->scope_lock; # lock the loop structures
     $timer = $loop->timer (5, 1, sub { $flag = 1 });
     $loop->notify; # tell loop to take note of the timer
  }
  
  1 while $flag; # $flag will be set asynchronously
  
  # implement a critical section, uninterrupted by any callbacks
  {
     $loop->interrupt->scope_block;
     # critical section, no watcher callback interruptions
  }
  
  # stop the timer watcher again - locking is required once more
  {
     $loop->scope_lock; # lock the loop structures
     $timer->stop;
     # no need to notify
  }

=head1 DESCRIPTION

This module implements a rather specialised event loop - it takes a normal
L<EV> event loop and runs it in a separate thread. That means it will poll
for events even while your foreground Perl interpreter is busy (you don't
need to have perls pseudo-threads enabled for this either).

Whenever the event loop detecs new events, it will interrupt perl and ask
it to invoke all the pending watcher callbacks. This invocation will be
"synchronous" (in the perl thread), but it can happen at any time.

See the documentation for L<Async::Interrupt> for details on when and how
your perl program can be interrupted (and how to avoid it), and how to
integrate background event loops into foreground ones.

=head1 FAQ

=over 4

=item Why on earth...???

Sometimes you need lower latency for specific events, but it's too heavy
to continuously poll for events. And perl already does this for you
anyways, so this module only uses this existing mechanism.

=item When do I have to lock?

When in doubt, lock. Do not start or stop a watcher, do not create a
watcher (unless with the C<_ns> methods) and do not DESTROY an active
watcher without locking either.

Any other event loop modifications need to be done while locked as
well. So when in doubt, lock (best using C<scope_lock>).

=item Why explicit locking?

Because I was too lazy to wrap everything and there are probably only a
few people on this world using this module.

=back

=head1 FUNCTIONS, METHODS AND VARIABLES OF THIS MODULE

=over 4

=cut

package EV::Loop::Async;

use common::sense;

use EV ();
use Async::Interrupt ();

use base 'EV::Loop';

BEGIN {
   our $VERSION = '0.03';

   require XSLoader;
   XSLoader::load ("EV::Loop::Async", $VERSION);
}

=item $loop = EV::Loop::Async::default

Return the default loop, usable by all programs. The default loop will be
created on the first call to C<default> by calling X<new EV::Loop>, and
should be used by all programs unless they have special requirements.

The associated L<Async::Interrupt> object is stored in
C<$EV::Loop::Async::AI>, and can be used to lock critical sections etc.

=cut

our ($LOOP, $INTERRUPT);

sub default() {
   $LOOP || do {
      $LOOP      = new EV::Loop::Async;
      $INTERRUPT = $LOOP->interrupt;

      $LOOP
   }
}

=item $EV::Loop::Async::LOOP

The default async loop, available after the first call to
C<EV::Loop::Async::default>.

=item $EV::Loop::Async::INTERRUPT

The default loop's L<Async::Interrupt> object, for easy access.

Example: create a section of code where no callback invocations will
interrupt:

   {
      $EV::Loop::Async::INTERRUPT->scope_block;
      # no default loop callbacks will be executed here.
      # the loop will not be locked, however.
   }

Example: embed the default EV::Async::Loop loop into the default L<EV>
loop (note that it could be any other event loop as well).

   my $async_w = EV::io
                    $EV::Loop::Async::LOOP->interrupt->pipe_fileno,
                    EV::READ,
                    sub { };

=item $loop = new EV::Loop::Async $flags, [Async-Interrupt-Arguments...]

This constructor:

=over 4

=item 1. creates a new C<EV::Loop> (similar C<new EV::Loop>).

=item 2. creates a new L<Async::Interrupt> object and attaches itself to it.

=item 3. creates a new background thread.

=item 4. runs C<< $loop->run >> in that thread.

=back

The resulting loop will be running and unlocked when it is returned.

Example: create a new loop, block it's interrupt object and embed
it into the foreground L<AnyEvent> event loop. This basically runs the
C<EV::Loop::Async> loop in a synchronous way inside another loop.

   my $loop  = new EV::Loop::Async 0;
   my $async = $loop->interrupt;

   $async->block;

   my $async_w = AnyEvent->io (
      fh => $async->pipe_fileno,
      poll => "r",
      cb => sub {
         # temporarily unblock to handle events
         $async->unblock;
         $async->block;
      },
   );

=cut

sub new {
   my ($class, $flags, @asy) = @_;

   my $self = bless $class->SUPER::new ($flags), $class;
   my ($c_func, $c_arg) = _c_func $self;
   my $asy = new Async::Interrupt @asy, c_cb => [$c_func, $c_arg];
   $self->_attach ($asy, $asy->signal_func);

   $self
}

=item $loop->notify

Wake up the asynchronous loop. This is useful after registering a new
watcher, to ensure that the background event loop integrates the new
watcher(s) (which only happens when it iterates, which you can force by
calling this method).

Without calling this method, the event loop I<eventually> takes notice
of new watchers, bit when this happens is not well-defined (can be
instantaneous, or take a few hours).

No locking is required.

Example: lock the loop, create a timer, nudge the loop so it takes notice
of the new timer, then evily busy-wait till the timer fires.

   my $timer;
   my $flag;

   {
      $loop->scope_lock;
      $timer = $loop->timer (1, 0, sub { $flag = 1 });
      $loop->notify;
   }

   1 until $flag;

=item $loop->lock

=item $loop->unlock

Lock/unlock the loop data structures. Since the event loop runs in
a separate thread, you have to lock the loop data structures before
accessing them in any way. Since I was lazy, you have to do this manually.

You must lock under the same conditions as you would have to lock the
underlying C library, e.g. when starting or stopping watchers (but not
when creating or destroying them, but note that create and destroy often
starts and stops for you, in which case you have to lock).

When in doubt, lock.

See also the next method, C<< $loop->scope_lock >> for a more failsafe way
to lock parts of your code.

Note that there must be exactly one call of "unblock" for every previous
call to "block" (i.e. calls can nest).

=item $loop->scope_lock

Calls C<lock> immediately, and C<unlock> automatically whent he current
scope is left.

=item $loop->set_max_foreground_loops ($max_loops)

The background loop will immediately stop polling for new events after it
has collected at least one new event, regardless of how long it then takes
to actually handle them.

When Perl finally handles the events, there could be many more ready
file descriptors. To improve latency and performance, you can ask
C<EV::Loop::Async> to loop an additional number of times in the foreground
after invoking the callbacks, effectively doing the polling in the
foreground.

The default is C<0>, meaning that no foreground polling will be done. A
value of C<1> means that, after handling the pending events, it will call
C<< $loop->loop (EV::LOOP_NONBLOCK) >> and handle the resulting events, if
any. A value of C<2> means that this will be iterated twice.

When a foreground event poll does not yield any new events, then no
further iterations will be made, so this is only a I<maximum> value of
additional loop runs.

Take also note of the standard EV C<set_io_collect_interval>
functionality, which can achieve a similar, but different, effect - YMMV.

=back

=head1 SEE ALSO

L<EV>, L<Async::Interrupt>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

