#!/usr/bin/perl
# deps.pl FILE FROM TO
# For lines FROM..TO of a Lua file: which file-level locals (declared at
# column 0 with `local`) the range USES but are declared outside it
# (imports), and which it DECLARES that are used outside it (exports).
# Comments and strings are stripped before matching. Heuristic: a name that
# is shadowed by an inner local still counts, so treat hits as "look here".
use strict; use warnings;
my ($file, $from, $to) = @ARGV;
open(my $fh, '<', $file) or die "cannot open $file";
my @lines = <$fh>; close $fh;

sub clean {
    my ($s) = @_;
    $s =~ s/"(?:[^"\\]|\\.)*"/""/g;
    $s =~ s/'(?:[^'\\]|\\.)*'/''/g;
    $s =~ s/--.*$//;
    return $s;
}

my (%declIn, %declOut);
for my $i (0..$#lines) {
    my $n = $i + 1;
    my $l = $lines[$i];
    next unless $l =~ /^local\s+(.*)$/;
    my $rest = $1;
    my @names;
    if ($rest =~ /^function\s+([A-Za-z_][A-Za-z0-9_]*)/) { @names = ($1); }
    else {
        my ($lhs) = split /=/, $rest, 2;
        @names = grep { /^[A-Za-z_][A-Za-z0-9_]*$/ } map { s/^\s+|\s+$//gr } split /,/, $lhs;
    }
    for my $nm (@names) {
        if ($n >= $from && $n <= $to) { $declIn{$nm} = $n } else { $declOut{$nm} //= $n }
    }
}

my (%imports, %exports);
for my $i (0..$#lines) {
    my $n = $i + 1;
    my $c = clean($lines[$i]);
    my $inside = ($n >= $from && $n <= $to);
    while ($c =~ /(?<![.:A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)/g) {
        my $w = $1;
        if ($inside && exists $declOut{$w} && !exists $declIn{$w}) { push @{$imports{$w}}, $n }
        if (!$inside && exists $declIn{$w}) { push @{$exports{$w}}, $n }
    }
}
print "IMPORTS (declared outside, used inside):\n";
for my $k (sort keys %imports) {
    my @u = @{$imports{$k}}; my %s; @u = grep { !$s{$_}++ } @u;
    printf "  %-34s decl %5d  used %d lines: %s\n", $k, $declOut{$k}, scalar(@u), join(',', @u[0..($#u<5?$#u:5)]);
}
print "EXPORTS (declared inside, used outside):\n";
for my $k (sort keys %exports) {
    my @u = @{$exports{$k}}; my %s; @u = grep { !$s{$_}++ } @u;
    printf "  %-34s decl %5d  used %d lines: %s\n", $k, $declIn{$k}, scalar(@u), join(',', @u[0..($#u<5?$#u:5)]);
}
