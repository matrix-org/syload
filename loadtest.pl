#!/usr/bin/env perl

use strict;
use warnings;
use 5.014; # package NAME { BLOCK }

use lib 'lib';
use lib '../sytest/lib'; # reuse some control features from SyTest

use Carp;

use Future;
use Future::Utils qw( repeat call_with_escape );
use IO::Async::Loop 0.66; # RT103446
use IO::Async::Resolver::StupidCache 0.02; # without_cancel bugfix
use Net::Async::HTTP;

use File::Path qw( make_path );
use File::Slurp qw( slurp );
use Getopt::Long qw( :config no_ignore_case gnu_getopt );
use List::Util 1.29 qw( max pairgrep );
use Sys::Hostname qw( hostname );
use Time::HiRes qw( time );

use SyLoad::Output;
use SyTest::Synapse;

use JSON::MaybeXS qw( JSON );
unless( JSON =~ m/::XS/ ) {
   warn "Not using an XS-based JSON parser might slow the load test down!";
}

STDOUT->autoflush(1);

my %TEST_PARAMS = (
   users => 20,
   rooms => 20,

   rates => [ 5 ],  # msg/sec
   duration => 120,  # seconds

   stat_interval => 5,  # seconds

   warmup => "1:60",  # rate:duration,...
);

my @SYNAPSE_EXTRA_ARGS;
GetOptions(
   'c|client-machine=s' => \my $CLIENT_MACHINE,
   'S|server-log+' => \my $SERVER_LOG,
   'server-grep=s' => \my @SERVER_FILTER,
   'd|synapse-directory=s' => \(my $SYNAPSE_DIR = "../synapse"),

   'u|users=i'  => \$TEST_PARAMS{users},
   'k|rooms=i'  => \$TEST_PARAMS{rooms},
   'rate=f'     => sub { $TEST_PARAMS{rates} = [ $_[1] ] }, ## LEGACY
   'rates=s'    => sub { $TEST_PARAMS{rates} = [ split m/,/, $_[1] ] },
   'duration=i' => \$TEST_PARAMS{duration},
   'cooldown=i' => \(my $DEFAULT_COOLDOWN = 10), # seconds
   'stat-interval=i' => \$TEST_PARAMS{stat_interval},

   'w|warmup=s' => \$TEST_PARAMS{warmup},

   'v|verbose+' => \(my $VERBOSE = 0),

   'n|no-tls' => \my $NO_TLS,

   'python=s' => \(my $PYTHON = "python"),

   'E=s' => sub { # process -Eoption=value
      my @more = split m/=/, $_[1];

      # Turn single-letter into -X but longer into --NAME
      $_ = ( length > 1 ? "--$_" : "-$_" ) for $more[0];

      push @SYNAPSE_EXTRA_ARGS, @more;
   },

   'output-dir|O=s' => \(my $OUTPUT_DIR),

   'h|help' => sub { usage(0) },
) or usage(1);

defined $CLIENT_MACHINE or
   die "Need to use an external machine for running the loadtest clients on\n";

push @SYNAPSE_EXTRA_ARGS, "-v" if $VERBOSE;

sub usage
{
   my ( $exitcode ) = @_;

   print STDERR <<'EOF';
loadtest.pl: [options...]

Options:
   -c, --client-machine HOST    - host to ssh to for running client instances

   -S, --server-log             - enable pass-through of server logs

       --server-grep PATTERN    - additionally, filter the server passthrough
                                  for matches of this pattern

   -d, --synapse-directory DIR  - path to the checkout directory of synapse

   -u, --users COUNT            - total number of users to create

   -k, --rooms COUNT            - total number of rooms to create
                                  Users will be distributed evenly among them

   --rates RATE,RATE,RATE,...   - list of rates in msgs/sec to test

   --duration SECS              - number of seconds to run for each rate

   --warmup RATE:SECS,RATE:SECS,...
                                - list of warmup rates and durations before
                                  starting the first test

   -v, --verbose                - increase the verbosity of output and
                                  synapse's logging level

   -n, --no-tls                 - use plain HTTP rather than HTTPS

       --python PATH            - path to the 'python' binary

   -ENAME,  -ENAME=VALUE        - pass extra argument NAME or NAME=VALUE

   -O, --output-dir DIR         - directory path to write result files into

EOF

   exit $exitcode;
}

# Largely to keep SyTest::Synapse happy
my $logger = bless {}, "SyLoad::Logger";
package SyLoad::Logger {
   sub diag { shift; print STDERR @_, "\n"; }
   sub progress { shift; print STDERR "\e[36m", @_, "\e[m\n"; }
}

my $loop = IO::Async::Loop->new;

# Cache DNS hits to avoid lots of extra resolver roundtrips to make every
# eventstream hit in all the NaMatrix HTTP clients
$loop->set_resolver(
   my $rcache = IO::Async::Resolver::StupidCache->new( source => $loop->resolver )
);

my %synapses_by_port;
END {
   $logger->diag( "Killing synapse servers " ) if %synapses_by_port;

   foreach my $synapse ( values %synapses_by_port ) {
      $synapse->kill( 'INT' );
   }
}
$SIG{INT} = sub { exit 1 };

sub extract_extra_args
{
   my ( $idx, $args ) = @_;

   return map {
      if( m/^\[(.*)\]$/ ) {
         # Extract the $idx'th element from a comma-separated list, or use the final
         my @choices = split m/,/, $1;
         $idx < @choices ? $choices[$idx] : $choices[-1];
      }
      else {
         $_;
      }
   } @$args;
}

# In case we ever want to do some "remote" federation-based load injection, add more ports here
my @PORTS = ( 8001 );
my @f;
foreach my $idx ( 0 .. $#PORTS ) {
   my $secure_port = $PORTS[$idx];
   my $unsecure_port = ( !$NO_TLS ) ? 0 : $secure_port + 1000;

   my @extra_args = extract_extra_args( $idx, \@SYNAPSE_EXTRA_ARGS );

   my $synapse = $synapses_by_port{$secure_port} = SyTest::Synapse->new(
      synapse_dir   => $SYNAPSE_DIR,
      port          => $secure_port,
      unsecure_port => $unsecure_port,
      output        => $logger,
      print_output  => $SERVER_LOG,
      extra_args    => [ @extra_args ],
      python        => $PYTHON,
      ( @SERVER_FILTER ? ( filter_output => \@SERVER_FILTER ) : () ),
   );
   $loop->add( $synapse );

   push @f, Future->wait_any(
      $synapse->started_future,

      $loop->delay_future( after => 20 )
         ->then_fail( "Synapse server on port $secure_port failed to start" ),
   );

   $synapse->start;
}

print STDERR "Starting synapse... ";
Future->needs_all( @f )->get;
print STDERR "done\n";

# Now the synapses are started there's no need to keep watching the logfiles
$_->close_logfile for values %synapses_by_port;

my $http = Net::Async::HTTP->new(
   SSL_verify_mode => 0,
);
$loop->add( $http );

sub fetch_metrics
{
   my ( $port ) = @_;

   ## TODO: This will require --enable-metrics to be passed to synapse, but
   #    as of 7b50769 it no longer takes this on the commandline.
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

# If we're running the clients on "localhost" then just telling them to connect
# back to "localhost" is fine; anything else we'd better pick our own name.
my $servername = ( $CLIENT_MACHINE eq "localhost" ) ? "localhost" : hostname();

my @client_cmdfutures;
my $clientctl = IO::Async::Process->new(
   command => [ 'ssh', $CLIENT_MACHINE, 'perl', '-',
      '--server' => $servername . ":" . ( $PORTS[0] + ( $NO_TLS ? 1000 : 0 ) ),
      ( $NO_TLS ? ( "--no-ssl" ) : () ),
      # '-v',
   ],

   stdio => {
      via => "pipe_rdwr",  # TODO: this ought not be necessary
      on_read => sub {
         my ( undef, $buffref ) = @_;
         while( $$buffref =~ s/^(.*?)\n// ) {
            my $line = $1;
            ( my $cmd, $line ) = split m/\s+/, $line, 2;

            if( $cmd eq "OK" ) {
               my $f = shift @client_cmdfutures;
               $f->done( $line ) if $f;
            }
            elsif( $cmd eq "PROGRESS" ) {
               print STDERR "\e[1;36m[Remote]:\e[m$line\n";
            }
            else {
               warn "Incoming line $cmd $line\n";
            }
         }
         return 0;
      }
   },
   stderr => {
      on_read => sub {
         my ( undef, $buffref ) = @_;
         print STDERR "\e[1;31m[Remote]:\e[m$1\n" while $$buffref =~ s/^(.*?)\n//;
         return 0;
      },
   },

   on_finish => sub {
      my ( $self, $exitcode ) = @_;
      return unless $exitcode;

      print STDERR "Remote SSH failed - $exitcode\n";
   },
);
$loop->add( $clientctl );
END { $clientctl and $clientctl->kill( 'INT' ) }

# Send program
$clientctl->stdio->write( scalar( slurp "remote.pl" ) . "\n__END__\n" );

# Wait for it to start
Future->wait_any(
   $clientctl->stdio->read_until( "START\n" ),

   $loop->delay_future( after => 10 )
      ->then_fail( "Timed out waiting for remote SSH control process to start" )
)->get;

sub do_command
{
   my ( $command, %args ) = @_;

   $clientctl->stdio->write( "$command\n" );

   push @client_cmdfutures, my $f = $clientctl->loop->new_future;
   Future->wait_any(
      $f,

      $loop->delay_future( after => $args{timeout} // 10 )
         ->then_fail( "Timed out waiting for $command to complete" )
   )
}

$logger->progress( "Creating test users" );
do_command( "MKUSERS $TEST_PARAMS{users}", timeout => 50 )->get;

$logger->progress( "Creating test rooms" );
do_command( "MKROOMS $TEST_PARAMS{rooms}", timeout => 30 )->get;

$logger->progress( "Warming up" );
( repeat {
   my ( $rate, $duration ) = split m/:/, shift;

   # TODO: write some output to the terminal so the user doesn't get bored

   do_command( "RATE $rate" )->then( sub {
      $loop->delay_future( after => $duration )
   })
} foreach => [ split m/,/, $TEST_PARAMS{warmup} ] )->get;

sub test_at_rate
{
   my ( $rate ) = @_;

   my $output;
   if( defined $OUTPUT_DIR ) {
      -d $OUTPUT_DIR or make_path $OUTPUT_DIR;

      $output = SyLoad::Output->open(
         # TODO: configurable filename
         File::Spec->catfile( $OUTPUT_DIR, sprintf "N%dk%dR%d.dat", $TEST_PARAMS{users}, $TEST_PARAMS{rooms}, $rate )
      );

      # Headings
      $output->write( "# time", qw( total batch p10 p25 p50 p75 p90 p95 p99 ) );
   }

   $logger->progress( "Testing" );
   do_command( "RATE $rate" )->get;

   my $start = time;
   my $failcount = 0;
   my $cumulative_total = 0;
   Future->wait_any(
      $loop->delay_future( after => $TEST_PARAMS{duration} ),

      repeat {
         $loop->delay_future( after => $TEST_PARAMS{stat_interval} )->then( sub {
            do_command( "STATS" )
         })->then( sub {
            my ( $stats ) = @_;
            say "STATS: ", $stats;

            my %fields = map { m/^(.*?)=(.*)$/ ? ( $1, $2 ) : () } split m/\s+/, $stats;
            $cumulative_total += $fields{batch};

            $output->write( time - $start, $cumulative_total, @fields{qw( batch p10 p25 p50 p75 p90 p95 p99 )} ) if $output;

            if( $fields{p10} <= 1.0 ) {   ## also handles NaN
               $failcount = 0;
            }
            else {
               $failcount++;
            }

            return Future->fail( "E2E latency above 1000msec at p10 for 30sec; stopping test", ABORT => )
               if $failcount >= 6;

            Future->done;
         })
      } while => sub { !shift->failure }
   )->else_with_f( sub {
      my ( $f, $message, $name ) = @_;
      if( $name and $name eq "ABORT" ) {
         say $message;
         return Future->done;
      }
      return $f;
   })->get;

   do_command( "RATE 0" )->get;

   my %fields = map { m/^(.*?)=(.*)$/ ? ( $1, $2 ) : () } split m/\s+/, do_command( "STATS" )->get;
   $cumulative_total += $fields{batch};

   $output->write( time - $start, $cumulative_total, @fields{qw( batch p10 p25 p50 p75 p90 p95 p99 )} ) if $output;

   say "Final STATS for rate=$rate: ", do_command( "ALLSTATS" )->get;
}

test_at_rate( $_) for @{ $TEST_PARAMS{rates} };
