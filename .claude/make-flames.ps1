# Generates the animated flame sheets in Media\Alerts for the Kelerts buff
# images (Squizzumables_SpellAlerts.lua, BUNDLED_IMAGES):
#
#   flames_u.png       bottom and both sides
#   flames_sides.png   left and right only -- "( )" round the screen
#   flames_bottom.png  bottom only
#   flames_ring.png    all four edges
#   flames_arcs.png    "( )" -- two arcs round a centre, to frame a character
#                      (its own layout: 32 frames of 256x256, 8x4, 2048x1024);
#                      flames_arcs_1/_2/_4/_5.png are the same at other
#                      thicknesses (the plain name is level 3)
#
# Each is a FLIPBOOK: 32 frames of 512x256, 4 columns x 8 rows, on one
# 2048x2048 sheet (row-major, top-left first). The Lua side must agree:
# FLAME_SHEET there. Played at ~16 fps it loops every 2 seconds.
#
# Procedural and ours. Heat falls off with distance from each burning edge;
# fractal value noise breaks it into tongues and makes them flicker. The
# noise is PERIODIC along the time-scrolled axis, and that axis scrolls by
# exactly one period over the 32 frames, so the last frame flows into the
# first with no jump. Colour runs white-yellow (hottest) through orange to a
# dark red at the tips; alpha follows heat. Drawn with ADD blending in game,
# so overlapping flames brighten.
#
# The pixel work is C# compiled on the fly -- 4 million pixels per sheet with
# several noise octaves each is far too slow as PowerShell.
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-flames.ps1
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Alerts')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SqFlames {
    const int FW = 512, FH = 256, COLS = 4, ROWS = 8, FRAMES = 32, SHEET = 2048;
    const int PERIOD = 8;            // lattice cells per loop on the scrolled axis

    static double Hash(int x, int y, int seed) {
        unchecked {
            int h = x * 374761393 + y * 668265263 + seed * 2147483647;
            h = (h ^ (h >> 13)) * 1274126177;
            h = h ^ (h >> 16);
            return (h & 0x7fffffff) / 2147483647.0;
        }
    }
    static double Smooth(double t) { return t * t * (3 - 2 * t); }

    // Value noise, periodic in y with `period` lattice cells.
    static double Noise(double x, double y, int period, int seed) {
        int xi = (int)Math.Floor(x), yi = (int)Math.Floor(y);
        double xf = x - xi, yf = y - yi;
        int y0 = ((yi % period) + period) % period, y1 = (y0 + 1) % period;
        double a = Hash(xi, y0, seed), b = Hash(xi + 1, y0, seed);
        double c = Hash(xi, y1, seed), d = Hash(xi + 1, y1, seed);
        double u = Smooth(xf), v = Smooth(yf);
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
    }
    // Three octaves; each keeps the period an integer multiple so it still loops.
    static double Fbm(double x, double y, int seed) {
        return 0.55 * Noise(x, y, PERIOD, seed)
             + 0.30 * Noise(x * 2, y * 2, PERIOD * 2, seed + 11)
             + 0.15 * Noise(x * 4, y * 4, PERIOD * 4, seed + 23);
    }

    // Heat from one edge. d: distance in from the edge (fraction of the frame
    // height); s: position along it; phase 0..1 over the loop. Flames reach
    // ~22% of the height, broken up by noise scrolling away from the edge.
    static double EdgeHeat(double d, double s, double phase, int seed, double drift, double reach) {
        if (d > reach * 2.2) return 0;
        double scroll = phase * PERIOD;
        // Tongues: noise along the edge sets how far each one reaches, squared
        // so most stay low and a few lick up tall -- flames, not a band.
        double tongue = Fbm(s * 6.0, scroll * 0.5 + 0.37, seed + 101);
        tongue = tongue * tongue;
        double n = Fbm(s * 9.0 + drift * scroll, d * 11.0 - scroll, seed);
        double h = 1.0 - d / (reach * (0.30 + 1.9 * tongue));
        h += (n - 0.55) * 1.1;
        return h;
    }

    static void Color(double h, out byte r, out byte g, out byte b, out byte a) {
        if (h <= 0) { r = g = b = a = 0; return; }
        if (h > 1) h = 1;
        // Mostly red and orange; yellow only in the hottest cores, near-white
        // barely at all -- a solid yellow band read as a lit sign, not fire.
        double R, G, B;
        if (h < 0.45) { double t = h / 0.45; R = 0.40 + 0.55 * t; G = 0.02 + 0.16 * t; B = 0.0; }
        else if (h < 0.85) { double t = (h - 0.45) / 0.40; R = 0.95 + 0.05 * t; G = 0.18 + 0.47 * t; B = 0.02 * t; }
        else { double t = (h - 0.85) / 0.15; R = 1.0; G = 0.65 + 0.27 * t; B = 0.02 + 0.40 * t; }
        double A = Math.Min(1.0, h / 0.6);
        A = A * A * (3 - 2 * A) * 0.92;
        r = (byte)(R * 255); g = (byte)(G * 255); b = (byte)(B * 255); a = (byte)(A * 255);
    }

    // edges: 'b' bottom, 'l' left, 'r' right, 't' top.
    public static void Make(string path, string edges) {
        var bmp = new Bitmap(SHEET, SHEET, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, SHEET, SHEET);
        var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[SHEET * SHEET * 4];
        double aspect = (double)FW / FH;
        for (int f = 0; f < FRAMES; f++) {
            double phase = (double)f / FRAMES;
            int ox = (f % COLS) * FW, oy = (f / COLS) * FH;
            for (int y = 0; y < FH; y++) {
                for (int x = 0; x < FW; x++) {
                    double u = (x + 0.5) / FH, v = (y + 0.5) / FH;   // both in frame-height units
                    double heat = 0;
                    if (edges.IndexOf('b') >= 0) heat = Math.Max(heat, EdgeHeat(1.0 - v, u, phase, 1, 0, 0.17));
                    if (edges.IndexOf('t') >= 0) heat = Math.Max(heat, EdgeHeat(v, u, phase, 2, 0, 0.13));
                    // Side flames are shallower (they run the full height, so
                    // they cover far more screen) and drift UP the edge, as fire would.
                    if (edges.IndexOf('l') >= 0) heat = Math.Max(heat, EdgeHeat(u, v, phase, 3, 1.0, 0.13));
                    if (edges.IndexOf('r') >= 0) heat = Math.Max(heat, EdgeHeat(aspect - u, v, phase, 4, 1.0, 0.13));
                    byte r, g, b, a;
                    Color(heat, out r, out g, out b, out a);
                    int i = ((oy + y) * SHEET + (ox + x)) * 4;
                    px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = a;   // BGRA
                }
            }
        }
        Marshal.Copy(px, 0, data.Scan0, px.Length);
        bmp.UnlockBits(data);
        bmp.Save(path, ImageFormat.Png);
        bmp.Dispose();
    }

    // "( )": two arcs of fire round a centre -- meant to frame a character, not
    // the screen. 32 frames of 256x256, 8 columns x 4 rows, on 2048x1024 (the
    // Lua side's ARC_SHEET). Each arc is the left or right part of an ellipse,
    // tapering to nothing at its top and bottom; the noise scrolls UP the frame
    // so the flames rise along the curve, and it loops like the edge sheets.
    //
    // `thick` is the flames' reach (fraction of the frame); the Thickness
    // slider picks between five sheets drawn at different values (see the
    // bottom of this script). Thicker flames need room, so the ellipse
    // shrinks as they grow: rx = 0.47 - thick, ry = 0.53 - thick. The Lua side
    // scales the frame back up by the same ratio (ARC_LEVELS), so the arc's
    // centre line stays where the player placed it at every thickness.
    public static void MakeArcs(string path, double thick) {
        const int AW = 256, AH = 256, ACOLS = 8, SW = 2048, SH = 1024;   // 4 rows
        var bmp = new Bitmap(SW, SH, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, SW, SH), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[SW * SH * 4];
        double rx = 0.47 - thick, ry = 0.53 - thick;
        double halfSpan = 62 * Math.PI / 180;    // each arc covers +-62 degrees of its side
        for (int f = 0; f < FRAMES; f++) {
            double phase = (double)f / FRAMES, scroll = phase * PERIOD;
            int ox = (f % ACOLS) * AW, oy = (f / ACOLS) * AH;
            for (int y = 0; y < AH; y++) {
                for (int x = 0; x < AW; x++) {
                    double u = (x + 0.5) / AW - 0.5, v = 0.5 - (y + 0.5) / AH;  // centred, y up
                    double heat = 0;
                    for (int side = 0; side < 2; side++) {
                        double sx = side == 0 ? -u : u;               // mirror the right arc onto the left
                        double ang = Math.Atan2(v / ry, -sx / rx);      // 0 at the arc's middle
                        if (Math.Abs(ang) > halfSpan * 1.25) continue;
                        double rn = Math.Sqrt((sx / rx) * (sx / rx) + (v / ry) * (v / ry));
                        double d = Math.Abs(rn - 1.0) * rx;             // distance off the curve
                        // Taper towards both ends of the arc.
                        double along = Math.Abs(ang) / halfSpan;
                        double taper = along >= 1 ? 0 : 1 - along * along;
                        if (taper <= 0) continue;
                        double reach = thick * (0.35 + 0.65 * taper);
                        double tongue = Fbm(ang * 3.0 + side * 7, scroll * 0.5 + 0.37, 201 + side);
                        tongue = tongue * tongue;
                        // Outside the curve a little further than inside: the
                        // flames lean away from what they surround.
                        double dd = rn > 1 ? d * 0.8 : d * 1.4;
                        double n = Fbm(u * 9.0 + side * 3.1, -v * 9.0 + scroll, 301 + side);
                        double h = (1.0 - dd / (reach * (0.4 + 1.8 * tongue))) * taper;
                        h += (n - 0.55) * 1.0 * taper;
                        if (h > heat) heat = h;
                    }
                    byte r, g, b, a;
                    Color(heat, out r, out g, out b, out a);
                    int i = ((oy + y) * SW + (ox + x)) * 4;
                    px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = a;
                }
            }
        }
        Marshal.Copy(px, 0, data.Scan0, px.Length);
        bmp.UnlockBits(data);
        bmp.Save(path, ImageFormat.Png);
        bmp.Dispose();
    }
}
'@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($e in @(@('flames_u', 'blr'), @('flames_sides', 'lr'), @('flames_bottom', 'b'), @('flames_ring', 'blrt'))) {
    $path = Join-Path $OutDir ($e[0] + '.png')
    [SqFlames]::Make($path, $e[1])
    Write-Host ("wrote {0} ({1:N0} KB)" -f $path, ((Get-Item $path).Length / 1KB))
}
# The arcs at five thicknesses; level 3 keeps the original file name. The
# thick values must match ARC_LEVELS in Squizzumables_SpellAlerts.lua.
foreach ($a in @(@('flames_arcs_1', 0.05), @('flames_arcs_2', 0.09), @('flames_arcs', 0.13),
                 @('flames_arcs_4', 0.17), @('flames_arcs_5', 0.21))) {
    $path = Join-Path $OutDir ($a[0] + '.png')
    [SqFlames]::MakeArcs($path, $a[1])
    Write-Host ("wrote {0} ({1:N0} KB)" -f $path, ((Get-Item $path).Length / 1KB))
}
