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

use File::Slurp qw( slurp );
use Getopt::Long qw( :config no_ignore_case gnu_getopt );
use List::Util 1.29 qw( max pairgrep );
use Sys::Hostname qw( hostname );
use Time::HiRes qw( time );

use SyTest::Synapse;
use SyTest::Output::Term;

use JSON::MaybeXS qw( JSON );
unless( JSON =~ m/::XS/ ) {
   warn "Not using an XS-based JSON parser might slow the load test down!";
}

STDOUT->autoflush(1);

my %TEST_PARAMS = (
   users => 20,
   rooms =>  5,
);

my @SYNAPSE_EXTRA_ARGS;
GetOptions(
   'c|client-machine=s' => \my $CLIENT_MACHINE,
   'S|server-log+' => \my $SERVER_LOG,
   'server-grep=s' => \my @SERVER_FILTER,
   'd|synapse-directory=s' => \(my $SYNAPSE_DIR = "../synapse"),

   'duration=i' => \(my $DEFAULT_DURATION = 120), # seconds
   'cooldown=i' => \(my $DEFAULT_COOLDOWN = 10), # seconds

   'w|wait-at-end' => \my $WAIT_AT_END,

   'v|verbose+' => \(my $VERBOSE = 0),

   'n|no-tls' => \my $NO_SSL,

   'python=s' => \(my $PYTHON = "python"),

   'E=s' => sub { # process -Eoption=value
      my @more = split m/=/, $_[1];

      # Turn single-letter into -X but longer into --NAME
      $_ = ( length > 1 ? "--$_" : "-$_" ) for $more[0];

      push @SYNAPSE_EXTRA_ARGS, @more;
   },

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

# Cache DNS hits to avoid lots of extra resolver roundtrips to make every
# eventstream hit in all the NaMatrix HTTP clients
$loop->set_resolver(
   my $rcache = IO::Async::Resolver::StupidCache->new( source => $loop->resolver )
);

my %synapses_by_port;
END {
   $output->diag( "Killing synapse servers " ) if %synapses_by_port;

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

# We need two servers; a "local" and a "remote" one for federation-based tests
my @PORTS = ( 8001, 8002 );
my @f;
foreach my $idx ( 0 .. $#PORTS ) {
   my $port = $PORTS[$idx];
   my @extra_args = extract_extra_args( $idx, \@SYNAPSE_EXTRA_ARGS );

   my $synapse = $synapses_by_port{$port} = SyTest::Synapse->new(
      synapse_dir  => $SYNAPSE_DIR,
      port         => $port,
      output       => $output,
      print_output => $SERVER_LOG,
      extra_args   => [ @extra_args ],
      python       => $PYTHON,
      no_ssl       => $NO_SSL,
      ( @SERVER_FILTER ? ( filter_output => \@SERVER_FILTER ) : () ),
   );
   $loop->add( $synapse );

   push @f, Future->wait_any(
      $synapse->started_future,

      $loop->delay_future( after => 20 )
         ->then_fail( "Synapse server on port $port failed to start" ),
   );
}

Future->needs_all( @f )->get;

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

my @client_cmdfutures;
my $clientctl = IO::Async::Process->new(
   command => [ 'ssh', $CLIENT_MACHINE, 'perl', '-',
      '--server' => hostname() . ":" . ( $PORTS[0] + ( $NO_SSL ? 100 : 0 ) ),
      ( $NO_SSL ? ( "--no-ssl" ) : () ),
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

$output->start_prepare( "Creating test users" );
do_command( "MKUSERS $TEST_PARAMS{users}", timeout => 50 )->get;
$output->pass_prepare;

$output->start_prepare( "Creating test rooms" );
do_command( "MKROOMS $TEST_PARAMS{rooms}", timeout => 30 )->get;
$output->pass_prepare;

do_command( "RATE 20" )->get;
Future->wait_any(
   $loop->delay_future( after => 30 ),

   repeat {
      do_command( "STATS" )
         ->then( sub {
            my @stats = @_;
            say "STATS: ", @stats;
            $loop->delay_future( after => 5 )
         })
   } while => sub { !shift->failure }
)->get;
say "Final STATS: ", do_command( "STATS" )->get;
do_command( "RATE 0" )->get;
