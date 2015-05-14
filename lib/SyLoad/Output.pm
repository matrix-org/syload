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
   }, $class;
}

package SyLoad::Output::CSV;
use base qw( SyLoad::Output );

sub write
{
   my $self = shift;
   $self->{fh}->print( join( ", ", @_ ), "\n" );
}

package SyLoad::Output::DAT;
# A space-separated format for gnuplot to use
use base qw( SyLoad::Output );

sub write
{
   my $self = shift;
   $self->{fh}->print( join( " ", @_ ), "\n" );
}

1;
