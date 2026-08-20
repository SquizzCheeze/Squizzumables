#!/usr/bin/perl
# Report backslashes that are neither part of a doubled pair nor a recognised
# Lua escape. A lone backslash before a letter -- "Fonts\FRIZQT__.TTF" -- is the
# failure mode worth catching: Lua treats it as an unknown escape and silently
# drops it, so the path is wrong at runtime with no error at load.
use strict;
use warnings;

my $bad = 0;
for my $file (@ARGV) {
    open(my $fh, '<', $file) or die "cannot open $file: $!";
    while (my $line = <$fh>) {
        my $probe = $line;
        next if $line =~ /^\s*--/;        # comments can say whatever they like
        $probe =~ s/\\\\//g;              # doubled separators are fine
        $probe =~ s/\\[0-9]{1,3}//g;      # numeric escapes, eg \226\128\148 (em dash)
        $probe =~ s/\\[ntrab"']//g;       # recognised single-char escapes are fine
        if ($probe =~ /\\/) {
            print "  $file:$.: $line";
            $bad++;
        }
    }
    close($fh);
}
print $bad == 0 ? "(clean: every backslash is a doubled pair or a known escape)\n"
                : "($bad suspicious line(s))\n";
