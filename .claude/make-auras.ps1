# Generates the "placed" aura images in Media\Alerts for the Kelerts buff
# images (Squizzumables_SpellAlerts.lua, BUNDLED_IMAGES) -- the shapes meant
# to frame your character rather than the screen's edge. The ( ) flame arcs
# live in make-flames.ps1; everything else is here.
#
# Animated -- FLIPBOOKS in the arcs' layout (ARC_SHEET on the Lua side):
# 32 frames of 256x256, 8 columns x 4 rows, on 2048x1024, played at 16 fps
# so each loops every 2 seconds. Every one is built to loop seamlessly: time
# enters only through phase = frame / 32, inside periodic functions.
#
#   aura_lightning.png  ( ) arcs of jagged lightning, forking, re-striking
#                       every 2 frames (deliberately not smooth)
#   aura_frost.png      ( ) arcs of ice: band, shards, rising mist, twinkles
#   aura_heart.png      a glowing heart beating twice per loop (lub-dub)
#   aura_arcane.png     two rune rings, orbs orbiting in opposite directions
#
# Static -- one 512x512 image each:
#
#   aura_wings.png      feathered wings (drawn opaque, for BLEND)
#   aura_bubble.png     a shield bubble: fresnel rim, highlight, lattice
#   aura_sunburst.png   golden rays round an empty centre
#   aura_runes.png      a summoning circle: rings, ticks, runes, hexagram
#
# Every effect but the wings is a HEAT field (0..1+) coloured through a
# three-stop palette, with alpha following heat; they are drawn with ADD
# blending in game, so they glow and the dark parts vanish. Coordinates are
# centred, y up, the frame spanning -0.5..0.5.
#
# C# compiled on the fly, as in make-flames.ps1 (far too slow as PowerShell).
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-auras.ps1
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Alerts')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public abstract class SqEffect {
    public double[] Lo = { 0, 0, 0 }, Mid = { 1, 1, 1 }, Hi = { 1, 1, 1 };
    public virtual void Begin(int frame) { }
    public abstract double Heat(double u, double v);
    // Default colouring: heat through the palette. Wings override this.
    public virtual void Shade(double u, double v, out double r, out double g, out double b, out double a) {
        double h = Heat(u, v);
        if (h <= 0.002) { r = g = b = a = 0; return; }
        if (h > 1) h = 1;
        double[] p0, p1; double t;
        if (h < 0.5) { p0 = Lo; p1 = Mid; t = h / 0.5; } else { p0 = Mid; p1 = Hi; t = (h - 0.5) / 0.5; }
        r = p0[0] + (p1[0] - p0[0]) * t;
        g = p0[1] + (p1[1] - p0[1]) * t;
        b = p0[2] + (p1[2] - p0[2]) * t;
        a = Math.Min(1.0, h / 0.45);
        a = a * a * (3 - 2 * a);
    }
}

public static class SqAuras {
    public const int FW = 256, COLS = 8, FRAMES = 32, SW = 2048, SH = 1024, PERIOD = 8;

    static double Hash(int x, int y, int seed) {
        unchecked {
            int h = x * 374761393 + y * 668265263 + seed * 2147483647;
            h = (h ^ (h >> 13)) * 1274126177;
            h = h ^ (h >> 16);
            return (h & 0x7fffffff) / 2147483647.0;
        }
    }
    static double Smooth(double t) { return t * t * (3 - 2 * t); }
    static double Noise(double x, double y, int period, int seed) {
        int xi = (int)Math.Floor(x), yi = (int)Math.Floor(y);
        double xf = x - xi, yf = y - yi;
        int y0 = ((yi % period) + period) % period, y1 = (y0 + 1) % period;
        double a = Hash(xi, y0, seed), b = Hash(xi + 1, y0, seed);
        double c = Hash(xi, y1, seed), d = Hash(xi + 1, y1, seed);
        double u = Smooth(xf), v = Smooth(yf);
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
    }
    // Periodic in y (PERIOD cells), so scrolling y by PERIOD over a loop is seamless.
    public static double Fbm(double x, double y, int seed) {
        return 0.55 * Noise(x, y, PERIOD, seed)
             + 0.30 * Noise(x * 2, y * 2, PERIOD * 2, seed + 11)
             + 0.15 * Noise(x * 4, y * 4, PERIOD * 4, seed + 23);
    }
    public static double SegDist(double px, double py, double ax, double ay, double bx, double by) {
        double dx = bx - ax, dy = by - ay;
        double l2 = dx * dx + dy * dy;
        double t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
        if (t < 0) t = 0; else if (t > 1) t = 1;
        double ex = ax + t * dx - px, ey = ay + t * dy - py;
        return Math.Sqrt(ex * ex + ey * ey);
    }
    public static double G(double d, double w) { double x = d / w; return Math.Exp(-x * x); }
    public static double Clamp01(double x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
    public static double SmoothStep(double e0, double e1, double x) {
        double t = Clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t);
    }
    // Wrap an angle into [0, 2pi).
    public static double Wrap(double a) { a %= 2 * Math.PI; return a < 0 ? a + 2 * Math.PI : a; }

    // A twinkle that loops: k whole cycles per loop.
    public static double Twinkle(double phase, int k, double off) {
        double s = Math.Sin(2 * Math.PI * (phase * k + off));
        return s > 0 ? Math.Pow(s, 10) : 0;
    }
    // A four-pointed glint at (cx, cy).
    public static double Glint(double u, double v, double cx, double cy, double size) {
        double dx = Math.Abs(u - cx), dy = Math.Abs(v - cy);
        if (dx > size * 10 || dy > size * 10) return 0;
        double r = Math.Sqrt(dx * dx + dy * dy);
        return G(r, size) + 0.6 * Math.Exp(-dx / (size * 0.6)) * Math.Exp(-dy / (size * 6))
                          + 0.6 * Math.Exp(-dy / (size * 0.6)) * Math.Exp(-dx / (size * 6));
    }

    public static void Render(SqEffect e, string path, bool animated, int size) {
        int fw = animated ? FW : size;
        int w = animated ? SW : size, h = animated ? SH : size;
        int frames = animated ? FRAMES : 1;
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[w * h * 4];
        for (int f = 0; f < frames; f++) {
            e.Begin(f);
            int ox = (f % COLS) * fw, oy = (f / COLS) * fw;
            for (int y = 0; y < fw; y++) {
                for (int x = 0; x < fw; x++) {
                    double u = (x + 0.5) / fw - 0.5, v = 0.5 - (y + 0.5) / fw;
                    double r, g, b, a;
                    e.Shade(u, v, out r, out g, out b, out a);
                    int i = ((oy + y) * w + (ox + x)) * 4;
                    px[i] = (byte)(Clamp01(b) * 255); px[i + 1] = (byte)(Clamp01(g) * 255);
                    px[i + 2] = (byte)(Clamp01(r) * 255); px[i + 3] = (byte)(Clamp01(a) * 255);
                }
            }
        }
        Marshal.Copy(px, 0, data.Scan0, px.Length);
        bmp.UnlockBits(data);
        bmp.Save(path, ImageFormat.Png);
        bmp.Dispose();
    }
}

// Segments with a bounding box and a weight, for the line-drawn effects.
public class SqSegs {
    public List<double[]> S = new List<double[]>();   // ax, ay, bx, by, weight, minx, maxx, miny, maxy
    public void Add(double ax, double ay, double bx, double by, double wt) {
        S.Add(new double[] { ax, ay, bx, by, wt, Math.Min(ax, bx), Math.Max(ax, bx), Math.Min(ay, by), Math.Max(ay, by) });
    }
    // Core line (width cw) as a max, plus a soft halo (width hw) summed and capped.
    public void Sample(double u, double v, double cw, double hw, double margin, out double core, out double halo) {
        core = 0; halo = 0;
        foreach (var s in S) {
            if (u < s[5] - margin || u > s[6] + margin || v < s[7] - margin || v > s[8] + margin) continue;
            double d = SqAuras.SegDist(u, v, s[0], s[1], s[2], s[3]);
            double c = s[4] * SqAuras.G(d, cw);
            if (c > core) core = c;
            halo += s[4] * SqAuras.G(d, hw);
        }
        if (halo > 1) halo = 1;
    }
}

// The ellipse the ( ) arcs follow -- the flame arcs' level 3 geometry, so all
// the arcs line up with each other at the same Size.
public static class SqArc {
    public const double RX = 0.34, RY = 0.40;
    public static readonly double Span = 62 * Math.PI / 180;
    // Point on the arc of side sgn (-1 left, +1 right) at angle a (0 = middle).
    public static void Point(double sgn, double a, out double x, out double y) {
        x = sgn * RX * Math.Cos(a); y = RY * Math.Sin(a);
    }
    // Outward unit normal there.
    public static void Normal(double sgn, double a, out double nx, out double ny) {
        nx = sgn * Math.Cos(a) / RX; ny = Math.Sin(a) / RY;
        double l = Math.Sqrt(nx * nx + ny * ny); nx /= l; ny /= l;
    }
    // Distance off the arc of side sgn, the angle along it, and the taper
    // towards its two ends (1 in the middle, 0 at the tips).
    public static void Locate(double u, double v, double sgn, out double d, out double ang, out double taper) {
        double sx = sgn * u;
        ang = Math.Atan2(v / RY, sx / RX);
        double rn = Math.Sqrt((sx / RX) * (sx / RX) + (v / RY) * (v / RY));
        d = Math.Abs(rn - 1.0) * RX;
        double along = Math.Abs(ang) / Span;
        taper = along >= 1 ? 0 : 1 - along * along;
    }
}

public class SqLightning : SqEffect {
    SqSegs segs = new SqSegs();
    double flash;
    public SqLightning() { Lo = new[] { 0.15, 0.25, 0.85 }; Mid = new[] { 0.45, 0.70, 1.0 }; Hi = new[] { 0.95, 0.97, 1.0 }; }
    public override void Begin(int f) {
        segs = new SqSegs();
        // A new strike every 2 frames (8 a second): lightning should snap,
        // not glide. The loop seam is just another strike.
        var rng = new Random((f / 2) * 7919 + 13);
        flash = 0.7 + 0.3 * rng.NextDouble();
        for (int side = 0; side < 2; side++) {
            double sgn = side == 0 ? -1 : 1;
            int n = 30;
            double off = 0, prevX = 0, prevY = 0;
            var ptsX = new double[n + 1]; var ptsY = new double[n + 1];
            for (int i = 0; i <= n; i++) {
                double a = -SqArc.Span * 1.05 + 2.1 * SqArc.Span * i / n;
                off += (rng.NextDouble() - 0.5) * 0.06;
                off *= 0.55;
                double o = off * (0.3 + 0.7 * Math.Sin(Math.PI * i / n));
                double x, y, nx, ny;
                SqArc.Point(sgn, a, out x, out y);
                SqArc.Normal(sgn, a, out nx, out ny);
                x += nx * o; y += ny * o;
                ptsX[i] = x; ptsY[i] = y;
                if (i > 0) segs.Add(prevX, prevY, x, y, 1.0);
                prevX = x; prevY = y;
            }
            // Forks: mostly outward, wandering, fainter than the main bolt.
            int forks = 2 + rng.Next(3);
            for (int k = 0; k < forks; k++) {
                int at = rng.Next(5, n - 5);
                double a = -SqArc.Span * 1.05 + 2.1 * SqArc.Span * at / n;
                double nx, ny;
                SqArc.Normal(sgn, a, out nx, out ny);
                double dirSign = rng.NextDouble() < 0.75 ? 1 : -1;
                double ang = Math.Atan2(ny * dirSign, nx * dirSign) + (rng.NextDouble() - 0.5) * 1.2;
                double x = ptsX[at], y = ptsY[at];
                int steps = 5 + rng.Next(4);
                for (int s = 0; s < steps; s++) {
                    ang += (rng.NextDouble() - 0.5) * 1.0;
                    double nx2 = x + Math.Cos(ang) * 0.017, ny2 = y + Math.Sin(ang) * 0.017;
                    segs.Add(x, y, nx2, ny2, 0.55 * (1 - 0.08 * s));
                    x = nx2; y = ny2;
                }
            }
        }
    }
    public override double Heat(double u, double v) {
        double core, halo;
        segs.Sample(u, v, 0.0032, 0.02, 0.07, out core, out halo);
        return flash * (core + 0.45 * halo);
    }
}

public class SqFrost : SqEffect {
    SqSegs shards = new SqSegs();
    List<double[]> sparks = new List<double[]>();   // x, y, k, offset
    double phase;
    public SqFrost() {
        Lo = new[] { 0.15, 0.35, 0.65 }; Mid = new[] { 0.55, 0.85, 1.0 }; Hi = new[] { 0.95, 1.0, 1.0 };
        var rng = new Random(42);
        for (int side = 0; side < 2; side++) {
            double sgn = side == 0 ? -1 : 1;
            for (int i = 0; i < 16; i++) {
                double a = -SqArc.Span * 0.9 + 1.8 * SqArc.Span * (i + rng.NextDouble() * 0.6) / 16;
                double x, y, nx, ny;
                SqArc.Point(sgn, a, out x, out y);
                SqArc.Normal(sgn, a, out nx, out ny);
                double dir = rng.NextDouble() < 0.7 ? 1 : -1;
                double rot = (rng.NextDouble() - 0.5) * 0.9;
                double cx = nx * Math.Cos(rot) - ny * Math.Sin(rot), cy = nx * Math.Sin(rot) + ny * Math.Cos(rot);
                double len = (dir > 0 ? 0.03 + rng.NextDouble() * 0.045 : 0.015 + rng.NextDouble() * 0.02)
                             * (1 - 0.6 * Math.Abs(a) / SqArc.Span);
                shards.Add(x, y, x + cx * len * dir, y + cy * len * dir, 1.0);
            }
            for (int i = 0; i < 22; i++) {
                double a = (rng.NextDouble() * 2 - 1) * SqArc.Span;
                double x, y, nx, ny;
                SqArc.Point(sgn, a, out x, out y);
                SqArc.Normal(sgn, a, out nx, out ny);
                double o = (rng.NextDouble() - 0.3) * 0.08;
                sparks.Add(new[] { x + nx * o, y + ny * o, (double)(1 + rng.Next(2)), rng.NextDouble() });
            }
        }
    }
    public override void Begin(int f) { phase = (double)f / SqAuras.FRAMES; }
    public override double Heat(double u, double v) {
        double h = 0;
        for (int side = 0; side < 2; side++) {
            double sgn = side == 0 ? -1 : 1;
            double d, ang, taper;
            SqArc.Locate(u, v, sgn, out d, out ang, out taper);
            if (taper <= 0) continue;
            // Ice: a band textured by sharpened static noise -- crystalline.
            double crystal = SqAuras.Fbm(u * 26 + side * 9, v * 26, 99 + side);
            crystal = Math.Min(1, crystal * crystal * crystal * 2.2);
            double band = taper * SqAuras.G(d, 0.02) * (0.5 + 0.5 * crystal);
            // Cold mist drifting up off it.
            double m = SqAuras.Fbm(u * 7 + side * 5, -v * 7 + phase * SqAuras.PERIOD, 50 + side);
            double mist = taper * SqAuras.G(d, 0.07) * Math.Max(0, m - 0.4) * 1.1;
            h = Math.Max(h, band) + mist;
        }
        // Shards: tapered spikes, solid ice.
        foreach (var s in shards.S) {
            if (u < s[5] - 0.02 || u > s[6] + 0.02 || v < s[7] - 0.02 || v > s[8] + 0.02) continue;
            double dx = s[2] - s[0], dy = s[3] - s[1], l2 = dx * dx + dy * dy;
            double t = SqAuras.Clamp01(((u - s[0]) * dx + (v - s[1]) * dy) / l2);
            double d = SqAuras.SegDist(u, v, s[0], s[1], s[2], s[3]);
            double wdt = 0.009 * (1 - t) + 0.0012;
            double c = SqAuras.Clamp01((wdt - d) / 0.0025) * (0.55 + 0.4 * (1 - t));
            c += 0.25 * SqAuras.G(d, 0.012);
            if (c > h) h = c;
        }
        foreach (var s in sparks) {
            double b = SqAuras.Twinkle(phase, (int)s[2], s[3]);
            if (b > 0.01) h += b * SqAuras.Glint(u, v, s[0], s[1], 0.004);
        }
        return h;
    }
}

public class SqHeart : SqEffect {
    const int N = 256;
    double[] dist = new double[N * N];
    bool[] inside = new bool[N * N];
    double scale = 1, beat = 0;
    public SqHeart() {
        Lo = new[] { 0.45, 0.0, 0.10 }; Mid = new[] { 1.0, 0.2, 0.4 }; Hi = new[] { 1.0, 0.85, 0.9 };
        // The classic parametric heart, centred and scaled to ~0.7 of the frame.
        int m = 360;
        var hx = new double[m]; var hy = new double[m];
        for (int i = 0; i < m; i++) {
            double t = 2 * Math.PI * i / m;
            double s = Math.Sin(t);
            hx[i] = 16 * s * s * s * 0.0225;
            hy[i] = (13 * Math.Cos(t) - 5 * Math.Cos(2 * t) - 2 * Math.Cos(3 * t) - Math.Cos(4 * t) + 2.5) * 0.0225;
        }
        for (int y = 0; y < N; y++) {
            for (int x = 0; x < N; x++) {
                double u = (x + 0.5) / N - 0.5, v = 0.5 - (y + 0.5) / N;
                double best = 9; bool inn = false;
                for (int i = 0, j = m - 1; i < m; j = i++) {
                    double d = SqAuras.SegDist(u, v, hx[j], hy[j], hx[i], hy[i]);
                    if (d < best) best = d;
                    if (((hy[i] > v) != (hy[j] > v)) && (u < (hx[j] - hx[i]) * (v - hy[i]) / (hy[j] - hy[i]) + hx[i])) inn = !inn;
                }
                dist[y * N + x] = best; inside[y * N + x] = inn;
            }
        }
    }
    public override void Begin(int f) {
        // Two beats per 2 s loop (60 bpm), each a lub and a softer dub.
        double p = ((double)f / SqAuras.FRAMES * 2) % 1.0;
        beat = SqAuras.G(p, 0.05) + SqAuras.G(p - 1, 0.05) + 0.6 * SqAuras.G(p - 0.17, 0.05);
        scale = 1 + 0.07 * beat;
    }
    public override double Heat(double u, double v) {
        double su = u / scale, sv = v / scale;
        double gx = (su + 0.5) * N - 0.5, gy = (0.5 - sv) * N - 0.5;
        if (gx < 0 || gy < 0 || gx >= N - 1 || gy >= N - 1) return 0;
        int ix = (int)gx, iy = (int)gy; double fx = gx - ix, fy = gy - iy;
        double d = (dist[iy * N + ix] * (1 - fx) + dist[iy * N + ix + 1] * fx) * (1 - fy)
                 + (dist[(iy + 1) * N + ix] * (1 - fx) + dist[(iy + 1) * N + ix + 1] * fx) * fy;
        d *= scale;
        double h = SqAuras.G(d, 0.011) + 0.4 * SqAuras.G(d, 0.05);
        if (inside[(int)Math.Round(gy) * N + (int)Math.Round(gx)]) h += 0.1 + 0.12 * beat;
        return h * (0.7 + 0.3 * beat);
    }
}

public class SqArcane : SqEffect {
    double phase;
    List<double[]> sparks = new List<double[]>();
    public SqArcane() {
        Lo = new[] { 0.30, 0.05, 0.55 }; Mid = new[] { 0.70, 0.35, 1.0 }; Hi = new[] { 1.0, 0.9, 1.0 };
        var rng = new Random(7);
        for (int i = 0; i < 26; i++) {
            double r = 0.2 + rng.NextDouble() * 0.26, a = rng.NextDouble() * 2 * Math.PI;
            sparks.Add(new[] { r * Math.Cos(a), r * Math.Sin(a), (double)(1 + rng.Next(3)), rng.NextDouble() });
        }
    }
    public override void Begin(int f) { phase = (double)f / SqAuras.FRAMES; }
    static double Ring(double r, double th, double R, int orbs, double turn, double dirSign) {
        double h = 0.35 * SqAuras.G(r - R, 0.004) + 0.1 * SqAuras.G(r - R, 0.03);
        for (int k = 0; k < orbs; k++) {
            double oa = 2 * Math.PI * (turn + (double)k / orbs);
            double ox = R * Math.Cos(oa), oy = R * Math.Sin(oa);
            // Trail BEHIND the orb, along its direction of travel.
            double behind = SqAuras.Wrap(dirSign * (oa - th));
            if (behind < 2.2) h += 0.8 * Math.Exp(-behind / 0.45) * SqAuras.G(r - R, 0.008);
            double dx = r * Math.Cos(th) - ox, dy = r * Math.Sin(th) - oy;
            double d = Math.Sqrt(dx * dx + dy * dy);
            h += 1.2 * SqAuras.G(d, 0.012) + 0.4 * SqAuras.G(d, 0.035);
        }
        return h;
    }
    public override double Heat(double u, double v) {
        double r = Math.Sqrt(u * u + v * v), th = Math.Atan2(v, u);
        // Outer ring: five orbs, one turn per loop, anticlockwise. Inner:
        // three, two turns per loop, clockwise -- both whole turns, so it loops.
        double h = Ring(r, th, 0.39, 5, phase, 1) + Ring(r, th, 0.28, 3, -2 * phase, -1);
        foreach (var s in sparks) {
            double b = SqAuras.Twinkle(phase, (int)s[2], s[3]);
            if (b > 0.01) h += 0.8 * b * SqAuras.Glint(u, v, s[0], s[1], 0.0035);
        }
        return h;
    }
}

public class SqBubble : SqEffect {
    public SqBubble() { Lo = new[] { 0.10, 0.35, 0.70 }; Mid = new[] { 0.40, 0.75, 1.0 }; Hi = new[] { 0.92, 0.98, 1.0 }; }
    public override double Heat(double u, double v) {
        const double R = 0.45;
        double r = Math.Sqrt(u * u + v * v), q = r / R, th = Math.Atan2(v, u);
        double h;
        if (q < 1) {
            h = 0.05 + 0.85 * Math.Pow(q, 8);
            // A faint triangular lattice, stronger towards the rim like the glow.
            double lines = 9;
            for (int k = 0; k < 3; k++) {
                double a = k * Math.PI / 3;
                double p = (u * Math.Cos(a) + v * Math.Sin(a)) / 0.07;
                double d = Math.Abs(p - Math.Floor(p + 0.5)) * 0.07;
                lines = Math.Min(lines, d);
            }
            h += 0.14 * SqAuras.G(lines, 0.0022) * q * q;
        } else {
            h = 0.9 * SqAuras.G(q - 1, 0.015);
        }
        // Glassy highlight: a crescent at the top left and a specular dot.
        double dth = Math.Atan2(Math.Sin(th - 2.35), Math.Cos(th - 2.35));
        h += 0.55 * SqAuras.G(r - 0.37, 0.022) * SqAuras.G(dth, 0.32);
        h += 0.6 * SqAuras.G(Math.Sqrt((u + 0.17) * (u + 0.17) + (v - 0.22) * (v - 0.22)), 0.022);
        return h;
    }
}

public class SqSunburst : SqEffect {
    public SqSunburst() { Lo = new[] { 0.60, 0.30, 0.0 }; Mid = new[] { 1.0, 0.75, 0.2 }; Hi = new[] { 1.0, 0.97, 0.8 }; }
    public override double Heat(double u, double v) {
        double r = Math.Sqrt(u * u + v * v), th = Math.Atan2(v, u);
        if (r < 0.09) return 0;
        // Rays narrow as they go out; long and short alternate.
        double sharp = 8 + 60 * r;
        double cl = Math.Cos(16 * th), cs = Math.Cos(16 * th + Math.PI);
        double longRay = (cl > 0 ? Math.Pow(cl, sharp) : 0) * (1 - SqAuras.SmoothStep(0.2, 0.49, r));
        double shortRay = (cs > 0 ? Math.Pow(cs, sharp) : 0) * (1 - SqAuras.SmoothStep(0.16, 0.34, r)) * 0.8;
        double h = (longRay + shortRay) * SqAuras.SmoothStep(0.1, 0.16, r);
        h += 0.6 * SqAuras.G(r - 0.13, 0.018) + 0.25 * SqAuras.G(r - 0.13, 0.07);
        return h;
    }
}

public class SqRunes : SqEffect {
    SqSegs lines = new SqSegs();
    public SqRunes() {
        Lo = new[] { 0.0, 0.35, 0.35 }; Mid = new[] { 0.2, 0.85, 0.8 }; Hi = new[] { 0.85, 1.0, 0.97 };
        // Hexagram inscribed in the inner ring.
        for (int t = 0; t < 2; t++) {
            for (int k = 0; k < 3; k++) {
                double a0 = Math.PI / 2 + t * Math.PI / 3 + k * 2 * Math.PI / 3;
                double a1 = a0 + 2 * Math.PI / 3;
                lines.Add(0.3 * Math.Cos(a0), 0.3 * Math.Sin(a0), 0.3 * Math.Cos(a1), 0.3 * Math.Sin(a1), 0.9);
            }
        }
        // Runes: twelve glyphs of 2-4 strokes between points of a 3x3 grid,
        // laid out round the band and turned to face the centre.
        var rng = new Random(1234);
        for (int g = 0; g < 12; g++) {
            double ga = 2 * Math.PI * (g + 0.5) / 12;
            double tx = -Math.Sin(ga), ty = Math.Cos(ga), rx = Math.Cos(ga), ry = Math.Sin(ga);
            double cx = 0.375 * rx, cy = 0.375 * ry;
            int strokes = 2 + rng.Next(3);
            for (int s = 0; s < strokes; s++) {
                int p0 = rng.Next(9), p1 = rng.Next(9);
                if (p0 == p1) p1 = (p1 + 4) % 9;
                double ax = (p0 % 3 - 1) * 0.018, ay = (p0 / 3 - 1) * 0.022;
                double bx = (p1 % 3 - 1) * 0.018, by = (p1 / 3 - 1) * 0.022;
                lines.Add(cx + tx * ax + rx * ay, cy + ty * ax + ry * ay, cx + tx * bx + rx * by, cy + ty * bx + ry * by, 1.0);
            }
        }
    }
    public override double Heat(double u, double v) {
        double r = Math.Sqrt(u * u + v * v), th = Math.Atan2(v, u);
        double h = 0;
        foreach (double R in new[] { 0.455, 0.43, 0.32, 0.30 }) h = Math.Max(h, SqAuras.G(r - R, 0.0032));
        // Ticks every 6 degrees between the two outer rings.
        if (r > 0.43 && r < 0.455) {
            double step = 2 * Math.PI / 60;
            double dth = Math.Abs(th / step - Math.Round(th / step)) * step * r;
            h = Math.Max(h, 0.8 * SqAuras.G(dth, 0.0022));
        }
        double core, halo;
        lines.Sample(u, v, 0.0032, 0.014, 0.04, out core, out halo);
        h = Math.Max(h, core);
        // A soft magical glow round everything.
        h += 0.22 * halo + 0.12 * SqAuras.G(r - 0.44, 0.03) + 0.1 * SqAuras.G(r - 0.31, 0.03);
        return h;
    }
}

// Wings: drawn as opaque feathers (BLEND in game), so they read on any
// background, with a soft golden glow behind.
public class SqWings : SqEffect {
    List<double[]> feathers = new List<double[]>();   // cx, cy, dirx, diry, halfLen, halfWidth
    public SqWings() {
        for (int side = 0; side < 2; side++) {
            double sgn = side == 0 ? -1 : 1;
            double sx = sgn * 0.07, sy = 0.08;
            // Back to front: primaries, secondaries, coverts.
            Layer(sgn, sx, sy, 10, -38, 58, 0.21, 0.11, 0.028, 0.10);
            Layer(sgn, sx, sy, 9, -60, 18, 0.15, 0.04, 0.031, 0.06);
            Layer(sgn, sx, sy, 6, -10, 55, 0.09, 0.02, 0.032, 0.05);
        }
    }
    void Layer(double sgn, double sx, double sy, int n, double a0, double a1, double len, double lenVar, double width, double reach) {
        for (int i = 0; i < n; i++) {
            double t = (double)i / (n - 1);
            double a = (a0 + (a1 - a0) * t) * Math.PI / 180;
            double L = len + lenVar * Math.Sin(Math.PI * t);
            // Bases spread along the wing's bone, up and out from the shoulder.
            double bx = sx + sgn * reach * t * Math.Cos(0.6), by = sy + reach * t * Math.Sin(0.6);
            double dx = sgn * Math.Cos(a), dy = Math.Sin(a);
            feathers.Add(new[] { bx + dx * L / 2, by + dy * L / 2, dx, dy, L / 2, width });
        }
    }
    public override double Heat(double u, double v) { return 0; }
    public override void Shade(double u, double v, out double r, out double g, out double b, out double a) {
        double topQ = 9, topAcross = 0, minQ = 9;
        foreach (var f in feathers) {
            double px = u - f[0], py = v - f[1];
            double along = (px * f[2] + py * f[3]) / f[4];
            if (along < -1.2 || along > 1.2) continue;
            double across = (-px * f[3] + py * f[2]);
            // Pointed towards the tip.
            double wdt = f[5] * (0.5 + 0.5 * (1 - Math.Max(0, along)));
            double ac = across / wdt;
            double q = Math.Sqrt(along * along + ac * ac);
            if (q < minQ) minQ = q;
            if (q < 1) { topQ = q; topAcross = ac; }   // later = in front
        }
        if (topQ < 1) {
            double shade = 0.8 + 0.2 * (1 - topQ * topQ);
            if (topQ > 0.84) shade *= 0.72;                        // feather outline
            if (Math.Abs(topAcross) < 0.07) shade *= 0.9;          // quill
            r = 1.0 * shade; g = 0.97 * shade; b = 0.88 * shade;
            a = SqAuras.Clamp01((1 - topQ) / 0.05);
            // Blend the anti-aliased edge into the glow below it.
            double ga = 0.35;
            r = r * a + 1.0 * (1 - a); g = g * a + 0.85 * (1 - a); b = b * a + 0.45 * (1 - a);
            a = a + ga * (1 - a);
        } else {
            double glow = minQ < 9 ? 0.35 * Math.Exp(-(minQ - 1) / 0.25) : 0;
            r = 1.0; g = 0.85; b = 0.45; a = glow;
        }
    }
}

public static class SqAuraMain {
    public static void Run(string dir) {
        SqAuras.Render(new SqLightning(), dir + "\\aura_lightning.png", true, 0);
        SqAuras.Render(new SqFrost(),     dir + "\\aura_frost.png",     true, 0);
        SqAuras.Render(new SqHeart(),     dir + "\\aura_heart.png",     true, 0);
        SqAuras.Render(new SqArcane(),    dir + "\\aura_arcane.png",    true, 0);
        SqAuras.Render(new SqWings(),     dir + "\\aura_wings.png",     false, 512);
        SqAuras.Render(new SqBubble(),    dir + "\\aura_bubble.png",    false, 512);
        SqAuras.Render(new SqSunburst(),  dir + "\\aura_sunburst.png",  false, 512);
        SqAuras.Render(new SqRunes(),     dir + "\\aura_runes.png",     false, 512);
    }
}
'@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$dir = (Resolve-Path $OutDir).Path
[SqAuraMain]::Run($dir)
Get-ChildItem $dir -Filter 'aura_*.png' | ForEach-Object { Write-Host ("wrote {0} ({1:N0} KB)" -f $_.Name, ($_.Length / 1KB)) }
