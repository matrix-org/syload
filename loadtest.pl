#!/usr/bin/env perl

use strict;
use warnings;
use 5.014; # package NAME { BLOCK }

use lib 'lib';
use lib '../sytest/lib'; # reuse some control features from SyTest

use Carp;

use Future;
use Future::Utils qw( repeat call_with_escape );
use IO::Async::Loop;
use Net::Async::HTTP;
use Net::Async::Matrix;

use Getopt::Long qw( :config no_ignore_case gnu_getopt );
use List::Util qw( max );
use Time::HiRes qw( time );

use SyTest::Synapse;
use SyTest::Output::Term;

STDOUT->autoflush(1);

my @SYNAPSE_EXTRA_ARGS;
GetOptions(
   'S|server-log+' => \my $SERVER_LOG,
   'server-grep=s' => \my @SERVER_FILTER,
   'd|synapse-directory=s' => \(my $SYNAPSE_DIR = "../synapse"),

   'w|wait-at-end' => \my $WAIT_AT_END,

   'v|verbose+' => \(my $VERBOSE = 0),

   'python=s' => \(my $PYTHON = "python"),

   'E=s' => sub { # process -Eoption=value
      my @more = split m/=/, $_[1];

      # Turn single-letter into -X but longer into --NAME
      $_ = ( length > 1 ? "--$_" : "-$_" ) for $more[0];

      push @SYNAPSE_EXTRA_ARGS, @more;
   },

   'h|help' => sub { usage(0) },
) or usage(1);

push @SYNAPSE_EXTRA_ARGS, "-v" if $VERBOSE;

sub usage
{
   my ( $exitcode ) = @_;

   print STDERR <<'EOF';
loadtest.pl: [options...]

Options:
   -S, --server-log             - enable pass-through of server logs

       --server-grep PATTERN    - additionally, filter the server passthrough
                                  for matches of this pattern

   -d, --synapse-directory DIR  - path to the checkout directory of synapse

   -w, --wait-at-end            - pause for input before shutting down testing
                                  synapse servers

   -v, --verbose                - increase the verbosity of output and
                                  synapse's logging level

       --python PATH            - path to the 'python' binary

   -ENAME,  -ENAME=VALUE        - pass extra argument NAME or NAME=VALUE

EOF

   exit $exitcode;
}

my $output = "SyTest::Output::Term";

my $loop = IO::Async::Loop->new;

my %synapses_by_port;
END {
   $output->diag( "Killing synapse servers " ) if %synapses_by_port;

   $_->kill( 'INT' ) for values %synapses_by_port;
}
$SIG{INT} = sub { exit 1 };

# We need two servers; a "local" and a "remote" one for federation-based tests
my @PORTS = ( 8001, 8002 );
my @f;
foreach my $port ( @PORTS ) {
   my $synapse = $synapses_by_port{$port} = SyTest::Synapse->new(
      synapse_dir  => $SYNAPSE_DIR,
      port         => $port,
      output       => $output,
      print_output => $SERVER_LOG,
      extra_args   => [ "--enable-metrics", @SYNAPSE_EXTRA_ARGS ],
      python       => $PYTHON,
      ( @SERVER_FILTER ? ( filter_output => \@SERVER_FILTER ) : () ),
   );
   $loop->add( $synapse );

   push @f, Future->wait_any(
      $synapse->started_future,

      $loop->delay_future( after => 20 )
         ->then_fail( "Synapse server on port $port failed to start" ),
   );
}

my $http = Net::Async::HTTP->new(
   SSL_verify_mode => 0,
);
$loop->add( $http );

sub fetch_metrics
{
   my ( $port ) = @_;

   $http->GET( "https://localhost:$port/_synapse/metrics" )->then( sub {
      my ( $response ) = @_;

      my %metrics;
      foreach my $line ( split m/\n/, $response->decoded_content ) {
         my ( $key, $value ) = $line =~ m/^(.*) +(\S+?)$/ or next;
         $metrics{$key} = $value;
      }

      Future->done( \%metrics );
   });
}

Future->needs_all( @f )->get;

my %USERS;

$output->start_prepare( "Creating test users" );

# First make some users
Future->needs_all( map {
   my $server_id = $_;

   my $port = $PORTS[$server_id];
   my $server = "localhost:$port";

   Future->needs_all( map {
      my $user_id = "u$_";
      my $password = join "", map { chr 32 + rand 95 } 1 .. 12;

      my $matrix = $USERS{"$user_id:$server"} = Net::Async::Matrix->new(
         server => $server,
         SSL             => 1,
         SSL_verify_mode => 0,
      );
      $loop->add( $matrix );
      $USERS{"$user_id:s$server_id"} = $matrix;

      $matrix->register(
         user_id  => $user_id,
         password => $password,
      )
   } 0 .. 3 )
} 0 .. $#PORTS )->get;

Future->wait_all( map { $_->start } values %USERS )->get;

$output->pass_prepare;

my $firstuser = $USERS{"u0:s0"};

$output->start_prepare( "Creating a test room" );
my $firstuser_room = $firstuser->create_room( "loadtest" )->get;
$output->pass_prepare;

my $room_alias = "#loadtest:localhost:$PORTS[0]";

sub ratelimit
{
   my ( $code, $interval, $progress ) = @_;

   $progress->() if $progress;

   my $overall_start = my $start = time();
   repeat {
      my ( $idx ) = @_;

      $start //= time();
      my $exp_end = ( $start += $interval );

      $code->()->then_with_f( sub {
         my ( $f ) = @_;
         my $now = time();

         $progress->( $idx, $now - $overall_start ) if $progress;

         return $f if $now > $exp_end;

         undef $start;
         return $loop->delay_future( at => $exp_end );
      });
   } generate => do { my $idx = 0; sub { $idx++ } },
     while => sub { not shift->failure };
}

sub strfduration
{
   my ( $d ) = @_;
   return sprintf           "%ds", $d if $d < 60;
   return sprintf      "%dm%02ds", $d / 60, $d % 60 if $d < 60*60;
   return sprintf "%dh%02dm%02ds", $d / (60*60), ( $d / 60 ) % 60, $d % 60;
}

sub test_this(&@)
{
   my ( $code, $name, %opts ) = @_;

   my $t = $output->enter_multi_test( $name );
   $t->start;

   my $interval = $opts{interval} // 0.01;

   # warmup
   $t->progress( "Warming up..." );
   my $warmup = $opts{warmup} // 20;
   Future->wait_any(
      $loop->delay_future( after => $warmup ),

      ratelimit( $code, $interval ),
   )->get;
   $t->ok( 1, "warmed up" );

   my $before = fetch_metrics( $PORTS[0] )->get;

   my $duration = $opts{duration} // 120;
   my $countlen = length strfduration $duration;
   my $count;
   my $last_print = 0;

   call_with_escape {
      my $escape = shift;

      ratelimit( $code, $interval, sub {
         my ( $idx, $overall_duration ) = @_;
         return unless defined $idx;

         $count = $idx, $escape->done if $overall_duration >= $duration;

         $t->progress( sprintf "[%*s/%s] running at %.2f/sec (done %d)",
               $countlen, strfduration($overall_duration), strfduration($duration), $idx / $overall_duration, $idx
         ), $last_print = time()
            if time() - $last_print > 1;
      })
   }->get;
   $t->ok( 1, "tested" );

   my $after = fetch_metrics( $PORTS[0] )->get;

   # TODO: cooldown time

   $t->leave;

   my %allkeys = ( %$before, %$after );
   my $maxkey = max( map { length } keys %allkeys );

   printf "%-*s | %11s | %11s\n", $maxkey, "Metric", "Before", "After";
   print  "-"x$maxkey . " | ----------- | -----------\n";

   foreach my $key ( sort keys %allkeys ) {
      my $was = $before->{$key};
      my $now = $after->{$key};

      next if defined $was and defined $now and $was == $now;

      printf "%-*s | %11s | %11s", $maxkey, $key, $was // "--", $now // "--";
      print("\n"), next if !defined $was or !defined $now;

      my $delta = $now - $was;
      if( $delta >= $count ) {
         printf "   \e[1;31m%+d\e[m (%.2f /call)\n", $delta, $delta / $count;
      }
      else {
         printf "   %+d\n", $delta;
      }
   }
}

###########
## Tests ##
###########

# TODO: some gut-wrenching here because it reaches inside the NaMatrix object
test_this { $firstuser->_do_GET_json( "/initialSync", limit => 0 ) }
   "/initialSync limit=0";

## Test local send, no viewers
$_->stop for values %USERS;

test_this { $firstuser_room->send_message( "Hello" ) }
   "send message to local room with no viewers at all";

## Test local send with myself viewing
$_->start for values %USERS;

test_this { $firstuser_room->send_message( "Hello" ) }
   "send message to local room with only myself viewing";

## Test local send with other local viewers
Future->needs_all( map { $USERS{"u$_:s0"}->join_room( $room_alias ) } 1 .. 3 )->get;

test_this { $firstuser_room->send_message( "Hello" ) }
   "send message to local room with other local viewers";

# TODO:
#   * test sending with remote viewers on federation
#   * test /remotes/ sending to us
#
#   * consider some EDU tests - typing notif?
