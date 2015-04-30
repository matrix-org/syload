## This code is sent over ssh to the remote 'perl' process running the
## loadtest clients

use strict;
use warnings;

use IO::Async::Loop 0.66; # RT103446
use IO::Async::Resolver::StupidCache;
use IO::Async::Stream;

use Getopt::Long;
use Struct::Dumb;

struct User => [qw( uid matrix room pending_f )];

GetOptions(
   'server=s' => \my $SERVER,
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
use Time::HiRes qw( time );

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
      ->on_done( sub { $self->write( "OK\n" ) } );
}

sub do_MKUSERS
{
   my $self = shift;
   my ( $count ) = @_;

   # First drop all the existing users
   # TODO

   fmap_void {
      my ( $idx ) = @_;
      my $uid = sprintf "u%06d", $idx;
      my $password = md5_base64( $uid . ":" . $PASSWORDKEY );

      my $matrix = Net::Async::Matrix->new(
         # TODO: consider no TLS?
         server          => $SERVER,
         SSL             => 1,
         SSL_verify_mode => 0,
      );
      $loop->add( $matrix );

      $USERS[$idx] = ::User( $uid, $matrix, undef, {} );

      # TODO: login or register
      $matrix->register(
         user_id => $uid,
         password => $password,
      )->then( sub {
         $matrix->start;
      })->on_done( sub {
         $self->progress( "Created $uid" )
      });
   } foreach => [ 0 .. $count-1 ],
     concurrent => 10;
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

         Future->needs_all( map {
            my $user = $_;

            $user->matrix->join_room( $room->room_id )->on_done( sub {
               my ( $room ) = @_;
               $user->room = $room;
            });
         } @joiners )->on_done( sub {
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

   my $t = time;
   $self->{rate_loop} = ( repeat {
      # TODO: consider typing notifications
      my $roomid = $ROOMIDS[$roomidx++];  $roomidx %= @ROOMIDS;
      my $users = $USERS_BY_ROOMID{$roomid};

      my $sender = $users->[rand @$users];

      my $this_msgidx = $msgidx++;

      my $start = time;
      my $send_time;
      my @recv_time;

      my @await_f;
      foreach my $useridx ( 0 .. $#$users ) {
         push @await_f, $users->[$useridx]->pending_f->{$this_msgidx} = Future->new
            ->on_done( sub { $recv_time[$useridx] = time - $start } );
      }

      my $send_and_await_f = $sender->room->send_message(
         type => "m.text",
         body => "A testing message here",
         'syload.msgidx' => $this_msgidx,
      )->then( sub {
         $send_time = time - $start;

         Future->wait_all( @await_f );
      });

      $self->adopt_future(
         Future->wait_any(
            $send_and_await_f,
            $loop->delay_future( after => 5 )->then_done(0),
         )->then( sub {
            my ( $success ) = @_;

            if( $success ) {
               my $recv_time = max @recv_time;
               printf STDERR "SENT in %.3f, ALL RECV in %.3f\n",
                  $send_time / 1000, $recv_time / 1000;

            }
            elsif( defined $send_time ) {
               my $partial_recv_time = max grep { defined } @recv_time;
               my $count_received = grep { defined } @recv_time;

               printf STDERR "SENT in %.3f, SOME RECV in %.3f, %d LOST\n",
                  $send_time / 1000, $partial_recv_time / 1000, scalar(@$users) - $count_received;
            }
            else {
               printf STDERR "SEND TIMEOUT\n";
            }

            # TODO: accumulate stats

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
