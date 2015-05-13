package SyLoad::Output;

use strict;
use warnings;
use feature qw( switch );

sub open
{
   my $class = shift;
   my ( $path ) = @_;

   my $outfh;
   for( $path ) {
      when( [ qr/\.csv$/, qr/\.dat$/ ] ) {
         $class = ( $path =~ m/\.csv$/ ) ? "SyLoad::Output::CSV" : "SyLoad::Output::DAT";
      }
      default {
         die "Unsure how to output to a file called $path\n";
      }
   }

   open $outfh, ">", $path or die "Cannot open $path for writing - $!\n";
   $outfh->autoflush(1);

   return bless {
      fh => $outfh,

      isfirst => 1,
      cumulative_total => 0,
   }, $class;
}

sub write
{
   my $self = shift;

   my ( $batch, @buckets ) = split m/\s+/, $_[0];
   my $time = $_[1];

   if( $self->{isfirst} ) {
      # column headings
      my @names = map { ( m/^(.*?)=/ )[0] } @buckets;
      $self->_write_fields( "# time", "total", "batch", @names );

      undef $self->{isfirst};
   }

   $_ = ( m/=(.*)/ )[0] for $batch, @buckets;

   $self->{cumulative_total} += $batch;
   $self->_write_fields( $time, $self->{cumulative_total}, $batch, @buckets );
}

package SyLoad::Output::CSV;
use base qw( SyLoad::Output );

sub _write_fields
{
   my $self = shift;
   $self->{fh}->print( join( ", ", @_ ), "\n" );
}

package SyLoad::Output::DAT;
# A space-separated format for gnuplot to use
use base qw( SyLoad::Output );

sub _write_fields
{
   my $self = shift;
   $self->{fh}->print( join( " ", @_ ), "\n" );
}

1;
