package SyLoad::Output;

use strict;
use warnings;
use feature qw( switch );

sub open
{
   my $class = shift;
   my ( $path ) = @_;

   my $cb;

   my $outfh;
   for( $path ) {
      when( [ qr/\.csv$/, qr/\.dat$/ ] ) {
         my $sep = ( $path =~ m/\.csv$/ ) ? ", " : " ";
         my $isfirst = 1;
         my $cumulative_total = 0;
         $cb = sub {
            my ( $batch, @buckets ) = split m/\s+/, $_[0];
            my $time = $_[1];

            if( $isfirst ) {
               # column headings
               my @names = map { ( m/^(.*?)=/ )[0] } @buckets;
               $outfh->print( "# ", join( $sep, "time", "total", "batch", @names ), "\n" );

               undef $isfirst;
            }

            $_ = ( m/=(.*)/ )[0] for $batch, @buckets;

            $cumulative_total += $batch;
            $outfh->print( join( $sep, $time, $cumulative_total, $batch, @buckets ), "\n" );
         };
      }
      default {
         die "Unsure how to output to a file called $path\n";
      }
   }

   open $outfh, ">", $path or die "Cannot open $path for writing - $!\n";
   $outfh->autoflush(1);

   return bless { cb => $cb }, $class;
}

sub write
{
   my $self = shift;
   $self->{cb}->( @_ );
}

1;
