#!/usr/bin/perl
# Every file listed in the .toc actually exists. Cheap, and the failure mode it
# catches -- a renamed or newly added file that never got listed, or listed with
# a typo -- shows up in game as a silent "half the addon did not load".
use strict;
use warnings;

my $toc = shift // 'Squizzumables.toc';
open(my $t, '<', $toc) or die "cannot open $toc: $!";
my $bad = 0;
while (my $line = <$t>) {
    $line =~ s/\s+$//;
    next if $line =~ /^\s*#/ or $line eq '';
    (my $path = $line) =~ s{\\}{/}g;
    if (-f $path) {
        print "ok   $line\n";
    } else {
        print "MISS $line\n";
        $bad++;
    }
}
close($t);

if ($bad == 0) {
    print "\n(clean: every .toc entry exists)\n";
} else {
    print "\n($bad missing)\n";
    exit 1;
}
