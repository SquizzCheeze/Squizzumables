#!/usr/bin/perl
# Catch strings that are syntactically broken, which the backslash checker
# cannot see.
#
# The failure mode this exists for: writing "\226\128\148" through a layer that
# treats \226 as octal collapses three escape sequences into one 0x96 byte, and
# the string then swallows the rest of the line. There is no backslash left to
# notice, so check-backslashes.pl reports it clean -- which is exactly what
# happened, three separate times.
#
# What breaks in Lua is the *unterminated string*, so that is what this looks
# for: a line with an odd number of unescaped double quotes. The mangled byte is
# reported alongside when there is one, since it is usually the cause.
#
# ORDER MATTERS, and getting it wrong is not theoretical -- the balance checker
# had this same bug. Strings must be removed BEFORE comments. Doing it the other
# way round means a "--" inside a string literal is mistaken for a comment
# marker, truncating the line and leaving a stray quote behind. Half this
# codebase's diagnostics print text containing " -- ".
use strict;
use warnings;

my $bad = 0;

for my $file (@ARGV) {
    open(my $fh, '<', $file) or die "cannot open $file: $!";
    while (my $line = <$fh>) {
        chomp(my $shown = $line);
        next if $line =~ /^\s*--/;          # whole-line comments say what they like

        my $probe = $line;
        $probe =~ s/\\\\//g;                # escaped backslashes first
        $probe =~ s/\\"//g;                 # escaped quotes are not delimiters
        $probe =~ s/'[^']*'//g;             # single-quoted strings
        $probe =~ s/"[^"]*"//g;             # balanced double-quoted strings
        $probe =~ s/--.*$//;                # only now can a -- be a comment

        # Anything left is a quote with no partner on this line.
        next unless $probe =~ /"/;

        my $note = "";
        if ($line =~ /([\x80-\xFF])/) {
            $note = sprintf(" (raw byte 0x%02X -- mangled escape?)", ord($1));
        }
        print "  $file:$.: unterminated string$note\n    $shown\n";
        $bad++;
    }
    close($fh);
}

print $bad == 0 ? "(clean: no unterminated strings)\n"
                : "($bad suspicious line(s))\n";
