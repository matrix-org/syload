## This code is sent over ssh to the remote 'perl' process running the
## loadtest clients

use strict;
use warnings;

BEGIN {
   my $homelib = "$ENV{HOME}/lib/perl5";
   unshift @INC, $homelib if -d $homelib;
}

use BSD::Resource qw( getrlimit setrlimit RLIMIT_NOFILE );

use IO::Async::Loop 0.66; # RT103446
use IO::Async::Resolver::StupidCache;
use IO::Async::Stream;

use Getopt::Long;
use Struct::Dumb;

struct User => [qw( uid matrix room pending_f )];

GetOptions(
   'server=s' => \my $SERVER,
   'no-ssl'   => \my $NO_SSL,
   'v+'       => \(my $VERBOSE = 0),
) or exit 1;

# Some secret that lets us reuse user accounts from one run to the next
my $PASSWORDKEY = "3u80532ohiow";

STDOUT->autoflush(1);

# Performance-enhancing additions

use IO::Async::Loop::Epoll;
use Heap;
use JSON::MaybeXS qw( JSON );
unless( JSON =~ m/::XS/ ) {
   warn "Not using an XS-based JSON parser might slow the load test down!";
}

# We're going to need a lot of filehandles
{
   my ( undef, $hardlimit ) = getrlimit( RLIMIT_NOFILE );
   setrlimit( RLIMIT_NOFILE, $hardlimit, $hardlimit ) or
      warn "Could not raise RLIMIT_NOFILE to $hardlimit - $!";
}

my $loop = IO::Async::Loop->new;
$loop->add( my $stdin_stream = CommandStream->new_for_stdio );

# Cache DNS hits to avoid lots of extra resolver roundtrips to make every
# eventstream hit in all the NaMatrix HTTP clients
$loop->set_resolver(
   my $rcache = IO::Async::Resolver::StupidCache->new( source => $loop->resolver )
);

print "START\n";
$stdin_stream->progress( "Remote SSH process running" );

$loop->run;

my @USERS;
my @ROOMIDS;
my %USERS_BY_ROOMID;

package CommandStream;
use base qw( IO::Async::Stream );

use Digest::MD5 qw( md5_base64 );
use Future::Utils qw( fmap_void repeat );
use List::Util qw( max );
use Time::HiRes qw( time gettimeofday tv_interval );

# All of the non performance-critical handling (like creating users and rooms)
# is done using NaMatrix
use Net::Async::Matrix;

sub on_read
{
   my $self = shift;
   my ( $buffref ) = @_;

   $self->adopt_future( $self->on_read_line( $1 )
      ->else( sub {
         my ( $message ) = @_;
         print STDERR "ERR: $message\n";
         Future->done;
      })
   ) while $$buffref =~ s/^(.*?)\n//;

   return 0;
}

sub progress
{
   my $self = shift;
   my ( $message ) = @_;

   $self->write( "PROGRESS $message\n" );
}

sub on_read_line
{
   my $self = shift;
   my ( $line ) = @_;

   my ( $cmd, @args ) = split m/\s+/, $line;

   my $code = $self->can( "do_$cmd" ) or
      return Future->fail( "Unknown command $cmd" );

   return $self->$code( @args )
      ->on_done( sub { $self->write( join( " ", "OK", @_ ) . "\n" ) } );
}

sub do_MKUSERS
{
   my $self = shift;
   my ( $count ) = @_;

   # First drop all the existing users
   # TODO

   # Create users WITHOUT eventstreams then start them

   my $create_f = fmap_void {
      my ( $idx ) = @_;
      my $uid = sprintf "u%06d", $idx;
      my $password = md5_base64( $uid . ":" . $PASSWORDKEY );

      my $matrix = Net::Async::Matrix->new(
         server          => $SERVER,
         ( $NO_SSL ?
            ( SSL             => 0 ) :
            ( SSL             => 1,
              SSL_verify_mode => 0 ) ),

         on_error => sub {
            my ( undef, $message ) = @_;
            print STDERR "NaMatrix for $uid failed: $message\n";
         },
      );
      $loop->add( $matrix );

      # Gut-wrench to turn off HTTP pipelining
      $matrix->{ua}->configure( pipeline => 0 );

      $USERS[$idx] = ::User( $uid, $matrix, undef, {} );

      # TODO: login or register
      $matrix->register(
         user_id => $uid,
         password => $password,
      )->on_done( sub {
         $matrix->stop;
         $self->progress( "Created $uid" )
      });
   } foreach => [ 0 .. $count-1 ],
     concurrent => 10;

   $create_f->then( sub {
      fmap_void {
         my $user = shift;

         $self->progress( "Starting ${\ $user->uid } eventstream" );
         $user->matrix->start;
      } foreach => [ @USERS ],
        concurrent => 10;
   });
}

sub do_MKROOMS
{
   my $self = shift;
   my ( $roomcount ) = @_;

   undef @ROOMIDS;

   my $useridx = 0;
   my $spare = 0;
   fmap_void {
      my ( $idx ) = @_;

      my $usercount = ( scalar @USERS ) / $roomcount;
      $spare += $usercount - int( $usercount );
      $usercount = int $usercount;

      $usercount++, $spare-- if $spare > 1;

      my @users = @USERS[$useridx .. $useridx + $usercount - 1];
      $useridx += $usercount;

      my ( $creator, @joiners ) = @users;

      # TODO: Does the room need a name?
      $creator->matrix->create_room( undef )->then( sub {
         my ( $room ) = @_;
         $creator->room = $room;

         $ROOMIDS[$idx] = $room->room_id;
         $self->progress( "Created room[$idx]" );

         ( repeat {
            my $user = shift;

            $user->matrix->join_room( $room->room_id )->on_done( sub {
               my ( $room ) = @_;
               $user->room = $room;
            });
         } foreach => [ @joiners ] )->on_done( sub {
            $USERS_BY_ROOMID{ $room->room_id } = [ $creator, @joiners ];

            foreach my $user ( @users ) {
               $user->room->configure( on_message => sub {
                  my ( undef, undef, $content ) = @_;
                  my $msgidx = $content->{"syload.msgidx"} or return;

                  if( my $f = delete $user->pending_f->{$msgidx} ) {
                     $f->done;
                  }
                  else {
                     print STDERR "Incoming content $content for ${\ $user->uid } msgidx $msgidx that we weren't expecting\n";
                  }
               });
            }

            $self->progress( "Joined room[$idx]" );
         });
      });
   } foreach => [ 0 .. $roomcount-1 ],
     concurrent => 10;
}

sub do_RATE
{
   my $self = shift;
   my ( $rate ) = @_;

   ( delete $self->{rate_loop} )->cancel if $self->{rate_loop};

   return Future->done unless $rate;

   # TODO: think about sending in bursts; groups of $b messages each at $rate/$b

   my $msgidx = 0;
   my $roomidx = 0;

   $self->{stats} = [];
   $self->{morestats} = \my @morestats;

   my $t = time;
   $self->{rate_loop} = ( repeat {
      # TODO: consider typing notifications
      my $roomid = $ROOMIDS[$roomidx++];  $roomidx %= @ROOMIDS;
      my $users = $USERS_BY_ROOMID{$roomid};

      my $sender = $users->[rand @$users];

      my $this_msgidx = $msgidx++;

      my $start = [ gettimeofday ];
      my $send_time;
      my @recv_time;

      my @await_f;
      foreach my $useridx ( 0 .. $#$users ) {
         push @await_f, $users->[$useridx]->pending_f->{$this_msgidx} = Future->new
            ->on_done( sub { $recv_time[$useridx] = tv_interval( $start ) } );
      }

      my $send_and_await_f = $sender->room->send_message(
         type => "m.text",
         body => "A testing message here",
         'syload.msgidx' => $this_msgidx,
      )->then( sub {
         $send_time = tv_interval( $start );

         Future->wait_all( @await_f );
      });

      $self->adopt_future(
         Future->wait_any(
            $send_and_await_f,
            $loop->delay_future( after => 5 )->then_done(0),
         )->then( sub {
            my ( $success ) = @_;

            my $sender_uid = $sender->uid;
            my $count_received = grep { defined } @recv_time;

            if( $success ) {
               my $recv_time = max @recv_time;
               printf STDERR "SENT [$sender_uid] in %.3f, ALL RECV in %.3f\n",
                  $send_time, $recv_time if $VERBOSE > 1;

               push @morestats, max( $send_time, $recv_time );
            }
            elsif( $count_received ) {
               my $partial_recv_time = max grep { defined } @recv_time;

               printf STDERR "SENT [$sender_uid] in %.3f, SOME RECV in %.3f, %d LOST\n",
                  $send_time, $partial_recv_time, scalar(@$users) - $count_received if $VERBOSE > 1;

               push @morestats, "Inf";
            }
            elsif( defined $send_time ) {
               printf STDERR "SENT [$sender_uid] in %.3f, ALL LOST\n",
                  $send_time if $VERBOSE;

               push @morestats, "Inf";
            }
            else {
               printf STDERR "SEND [$sender_uid] TIMEOUT\n" if $VERBOSE;

               push @morestats, "Inf";
            }

            Future->done;
         })->else( sub {
            my ( $failure ) = @_;
            print STDERR "FAIL $failure\n";

            Future->done;
         })
      );

      $t += ( 1 / $rate );
      $loop->delay_future( at => $t );
   } while => sub { !shift->failure } )
      ->on_fail( sub { die @_ } );

   Future->done;  # since we started OK
}

sub percentile
{
   my ( $arr, $pct ) = @_;
   my $idx = $#$arr * $pct / 100;
   my $frac = $idx - int( $idx );
   $idx = int $idx;

   if( $idx < $#$arr ) {
      return $arr->[$idx] * ( 1 - $frac ) + $arr->[1 + $idx] * $frac;
   }
   else {
      return $arr->[$idx];
   }
}

sub do_STATS
{
   my $self = shift;

   my @more = sort { $a <=> $b } @{ $self->{morestats} };
   undef @{ $self->{morestats} };

   my @result = (
      "batch=${\ scalar @more }",
      map { sprintf "p%02d=%.3f", $_, percentile( \@more, $_ ) } qw( 10 25 50 75 90 95 99 )
   );

   my @stats = @{ $self->{stats} };
   my @new;

   # Sorted merge
   while( @stats and @more ) {
      push @new, ( $stats[0] > $more[0] ) ? shift @more : shift @stats;
   }

   # Collect up whatever's left
   push @new, @more, @stats;

   $self->{stats} = \@new;

   Future->done( @result );
}

sub do_ALLSTATS
{
   my $self = shift;

   my $stats = $self->{stats};

   Future->done(
      "total=${\ scalar @$stats }",
      map { sprintf "p%02d=%.3f", $_, percentile( $stats, $_ ) } qw( 10 25 50 75 90 95 99 )
   );
}
