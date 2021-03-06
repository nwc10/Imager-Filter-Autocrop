package Imager::Filter::Autocrop;

use 5.006;
use strict;
use warnings;
use Imager;
use Imager::Color;

=head1 NAME

Imager::Filter::Autocrop - Automatic crop filter for Imager.

=head1 VERSION

Version 1.23

=head1 SYNOPSIS

    use Imager;
    use Imager::Filter::Autocrop;

    my $img = Imager->new();
    $img->read(file => 'image.jpg');
    $img->filter(type => 'autocrop') or die $img->errstr;

=head1 DESCRIPTION

This module extends C<Imager> functionality with the autocrop filter, similar to ImageMagick and GraphicsMagick "trim". It does
have a few additional features as well, such as support for the border or detection-only mode. The distribution also includes
a command-line script autocrop.pl.

Note: If the image looks blank (whether genuinely or because of the 'fuzz' parameter), or if there is nothing to crop,
then the filter call will return false and the 'errstr' method will return appropriate message.

=head1 NAME OVERRIDE

You can change the name under which the filter is registered, by specifying it in 'use' directive. For example, to change the
name to 'trim' from the default 'autocrop':

    use Imager;
    use Imager::Filter::Autocrop 'trim';

    $img->filter(type => 'trim') or die $img->errstr;

=head1 PARAMETERS

=over 12

=item C<color>

By default the color of the top left pixel is used for cropping. You can explicitly specify one though, by either
providing the '#RRGGBB' value or passing an object of C<Imager::Color> class or its subclass.

    # The following two calls are identical. 
    $img->filter(type => 'autocrop', color => "#FFFFFF");
    $img->filter(type => 'autocrop', color => Imager::Color->new(255, 255, 255));

=item C<fuzz>

You can specify the deviation for the color value (for all RGB channels or the main channel if it is a greyscale image),
by using the 'fuzz' parameter. All image colors within the range would be treated as matching candidates for cropping.
 
    $img->filter(type => 'autocrop', fuzz => 20);

=item C<border>

You can specify the border around the image for cropping. If the cropping area with the border is identical to the original
image height and width, then no actual cropping will be done.

    $img->filter(type => 'autocrop', border => 10);

=item C<detect>

Finally, you can just detect the cropping area by passing a hash reference as a 'detect' parameter. On success, your hash 
will be set with left, right, top and bottom keys and appropriate values. Please note that if the 'border' parameter is used, 
the detected area values will be adjusted appropriately.

    my %points = ();
    $img->filter(type => 'autocrop', detect => \%points);

=back

=cut

our $VERSION = '1.23';

sub autocrop {
    my (%params) = @_;
    my ($img, $fuzz, $border, $color, $detect) = @params{qw<imager fuzz border color detect>};
    $color||=$params{'colour'}; # Yes, we support British version too.
    # Check if colour is given, otherwise read the corner pixel.
    if ($color) {
        $color = Imager::Color->new($color) unless UNIVERSAL::isa($color, 'Imager::Color');
    } else {
        $color = $img->getpixel(x => 0, y => 0);
    }
    die "AUTOCROP_ERROR_COLOR: Color is not set correctly\n" unless defined $color;
    my ($r, $g, $b) = $color->rgba;
    my @range = ($r - $fuzz, $r + $fuzz,
                 $g - $fuzz, $g + $fuzz,
                 $b - $fuzz, $b + $fuzz);
    my %original = (left => 0, right => $img->getwidth, top => 0, bottom => $img->getheight);
    my $crop = _scan($img, \@range);
    my $bordered = 0;
    for (keys %original) { 
        if ($original{$_}) {
            $crop->{$_}+=$border;
            if ($crop->{$_} >= $original{$_}) {
                $crop->{$_} = $original{$_};
                $bordered++;
            }
        } else {
            $crop->{$_}-=$border;
            if ($crop->{$_} <= $original{$_}) {
                $crop->{$_} = $original{$_};
                $bordered++;
            }
        }
    }
    die "AUTOCROP_ERROR_NOCROP: Nothing to crop\n" if ($bordered == 4);
    if ($detect and ref $detect eq 'HASH') {
        %{$detect} = %{$crop};
    } else {
        my $rv = $img->crop(%{$crop}) or die $img->errstr; 
        $img->{IMG} = $rv->{IMG};
    }
} 

sub _scan {
    my ($image, $range) = @_;
    my $channels = $image->getchannels < 3 ? 1 : 3;
    my $getline = $channels == 3 ? '(CCCx)*' : '(Cxxx)*';
    my $out_of_range = $channels == 3 ? sub {
        my $scanned = shift;
        return 1
            if $scanned->[0] < $range->[0];
        return 1
            if $scanned->[0] > $range->[1];
        return 1
            if $scanned->[1] < $range->[2];
        return 1
            if $scanned->[1] > $range->[3];
        return 1
            if $scanned->[2] < $range->[4];
        return 1
            if $scanned->[2] > $range->[5];
        return 0;
    } : sub {
        my $scanned = shift;
        return 1
            if $scanned->[0] < $range->[0];
        return 1
            if $scanned->[0] > $range->[1];
        return 0;
    };

    # First, take as many complete lines off the bottom as is possible:
    my $bottom = $image->getheight;
    while (--$bottom >= 0) {
        my @colors = unpack $getline, $image->getscanline(y => $bottom);
        while (@colors) {
            last
                if $out_of_range->(\@colors, $range);
            splice @colors, 0, $channels;
        }
        last
            if @colors;
    }
    die "AUTOCROP_ERROR_BLANK: Image looks blank\n"
        if $bottom < 0;

    # Then, start from the top, removing complete lines.
    # When we fail, we could remember how far in we got but I think that this
    # adds too much complexity below. (it would be @colors / $channels)
    my $top = 0;
    while ($top <= $bottom) {
        my @colors = unpack $getline, $image->getscanline(y => $top);
        while (@colors) {
            last
                if $out_of_range->(\@colors, $range);
            splice @colors, 0, $channels;
        }
        last
            if @colors;
        ++$top;
    }

    my $width = $image->getwidth;
    my $left = $width;
    my $right = 0;
    my $current = $top;

    while ($current <= $bottom) {
        my @colors = unpack $getline, $image->getscanline(y => $current);
        my $this_row_left = 0;
        while (@colors) {
            last
                if $this_row_left == $left;
            if ($out_of_range->(\@colors, $range)) {
                $left = $this_row_left;
                last;
            }
            ++$this_row_left;
            splice @colors, 0, $channels;
        }
        my $this_row_right = $width;
        while (@colors) {
            last
                if $this_row_right == $right;
            my @color = splice @colors, -$channels, $channels;
            if ($out_of_range->(\@color, $range)) {
                $right = $this_row_right;
                last;
            }
            --$this_row_right;
        }
        # Nothing left to crop?
        last
            if $this_row_left == 0 && $this_row_right == $width;
        ++$current;
    }

    ++$bottom;

    return { top => $top, bottom => $bottom, left => $left, right => $right };
}

sub import {
    my ($self, $type) = @_;
    Imager->register_filter(
    type => $type||'autocrop',
    callsub => \&autocrop,
    callseq => [ 'image' ],
    defaults => {
        fuzz    => 0,
        border  => 0,
    });
}

=head1 SEE ALSO

L<http://search.cpan.org/perldoc?Imager>

=head1 AUTHOR

Alexander Yezhov, C<< <leader at cpan.org> >>
Domain Knowledge Ltd.
L<https://do-know.com/>

=head1 BUGS

Please report any bugs or feature requests to C<bug-imager-filter-autocrop at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Imager-Filter-Autocrop>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Imager::Filter::Autocrop


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Imager-Filter-Autocrop>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Imager-Filter-Autocrop>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Imager-Filter-Autocrop>

=item * Search CPAN

L<http://search.cpan.org/dist/Imager-Filter-Autocrop/>

=back


=head1 LICENSE AND COPYRIGHT

Copyright 2016 Alexander Yezhov.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;
