# .claude/gen-reveal.pl -- rebuilds Maps/RevealData_<Client>.lua from wago.tools DB2 CSVs.
# Fetch WorldMapOverlay.csv and WorldMapOverlayTile.csv into <dir> from
#   https://wago.tools/db2/<Table>/csv?build=<build>   (retail 12.1.5.x; Forever 1.60.1.x)
# then:  perl .claude/gen-reveal.pl <dir> <build> Retail "ns.BH.IS_FOREVER" > Maps/RevealData_Retail.lua
#        perl .claude/gen-reveal.pl <dir> <build> Forever "not ns.BH.IS_FOREVER" > Maps/RevealData_Forever.lua
# Flags 1/2 (4 retail rows) are skipped; Forever flag 4 is whole maps, kept.
use strict; use warnings;
my ($dir, $build, $client, $guard) = @ARGV;
my (%tiles, %ov);
open my $t, "<", "$dir/WorldMapOverlayTile.csv" or die; <$t>;
while (<$t>) { s/\r?\n//; my ($id,$row,$col,$layer,$fid,$ov) = split /,/; next if $layer; push @{$tiles{$ov}}, [$row,$col,$fid]; }
open my $o, "<", "$dir/WorldMapOverlay.csv" or die; <$o>;
my $skipped = 0;
while (<$o>) { s/\r?\n//; my @f = split /,/; my ($id,$art,$w,$h,$x,$y) = @f[0..5]; my $flags = $f[11];
  if ($flags & 3) { $skipped++; next } next unless $tiles{$id};
  my @ids = map { $_->[2] } sort { $a->[0] <=> $b->[0] or $a->[1] <=> $b->[1] } @{$tiles{$id}};
  next if grep { !$_ } @ids;
  push @{$ov{$art}}, "$w:$h:$x:$y:" . join(",", @ids); }
my $n = 0; $n += @$_ for values %ov;
print "-- Maps/RevealData_$client.lua\n-- GENERATED from the game's own map tables (WorldMapOverlay +\n-- WorldMapOverlayTile, build $build, via wago.tools DB2 exports). Every\n-- explorable area of each map's art: \"width:height:offsetX:offsetY:tile file IDs\",\n-- tiles row by row. Keyed by UiMapArtID (C_Map.GetMapArtID). Do not edit by hand.\n-- $n areas on ", scalar(keys %ov), " maps.\n\n";
print "local _, ns = ...\nif $guard then return end\n\nns.RevealData = {\n";
for my $art (sort { $a <=> $b } keys %ov) { print "    [$art] = {\n"; print "        \"$_\",\n" for sort @{$ov{$art}}; print "    },\n"; }
print "}\n";
print STDERR "$client: $n areas, ", scalar(keys %ov), " maps, $skipped flagged skipped\n";
