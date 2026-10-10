# Cuts the 12-frame "pixel art shark chomp cycle" (an AI-generated JPG the
# user supplied, 2026-10-11, cleared to ship) into a transparent flipbook for
# the cursor's shark bite: Media\Cursor\shark_bite.png, 4 x 4 grid of 256 x 256
# frames (12 used), plus a preview on two backgrounds.
#
# The source is a PICTURE of a sheet, not a sheet: a title strip, dark borders
# between cells, a label in each cell's corner, teal water behind every shark,
# and JPEG noise. So, per cell:
#   1. find the cells from the borders (columns / rows that are almost all
#      near-black);
#   2. flood-fill the WATER in from the cell's edges -- teal, with clearly more
#      green than red, and dark-to-mid; the shark's outline (very dark, low
#      green) and its light body stop the fill;
#   3. keep only the LARGEST remaining 8-connected blob -- the shark -- which
#      drops the corner label and stray ripple specks;
#   4. place every cell at the same offset in its 256 x 256 frame, so the shark
#      does not jitter from frame to frame.
#
#   powershell -ExecutionPolicy Bypass -File .claude\cut-shark.ps1 -Source g:\Downloads\Shark.jpg
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$OutDir,
    [string]$PreviewPath
)
$ErrorActionPreference = 'Stop'
# Defaults here, not in param(): $PSScriptRoot is empty while Windows
# PowerShell 5.1 evaluates parameter defaults.
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\Media\Cursor' }
if (-not $PreviewPath) { $PreviewPath = Join-Path $env:TEMP 'shark-preview.png' }
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SqShark {
    static int[] px; static int W, H;
    static int R(int x, int y) { return (px[y * W + x] >> 16) & 255; }
    static int G(int x, int y) { return (px[y * W + x] >> 8) & 255; }
    static int B(int x, int y) { return px[y * W + x] & 255; }
    static int Lum(int x, int y) { return (R(x, y) + G(x, y) + B(x, y)) / 3; }

    static bool Water(int x, int y) {
        int r = R(x, y), g = G(x, y), b = B(x, y);
        int lum = (r + g + b) / 3;
        return lum < 118 && r < 62 && g >= 38 && g * 100 >= b * 55;
    }

    // Runs of indices where `dark` holds, as (start, end) pairs.
    static List<int[]> Runs(bool[] dark) {
        var runs = new List<int[]>(); int s = -1;
        for (int i = 0; i <= dark.Length; i++) {
            bool d = i < dark.Length && dark[i];
            if (d && s < 0) s = i;
            if (!d && s >= 0) { runs.Add(new[] { s, i - 1 }); s = -1; }
        }
        return runs;
    }

    public static string Run(string src, string outPath, string previewPath) {
        var bmp = new Bitmap(src);
        W = bmp.Width; H = bmp.Height;
        var data = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        px = new int[W * H];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        bmp.UnlockBits(data); bmp.Dispose();

        // Borders: columns / rows that are near-black almost all the way.
        var colDark = new bool[W]; var rowDark = new bool[H];
        for (int x = 0; x < W; x++) { int n = 0; for (int y = 30; y < H - 10; y++) if (Lum(x, y) < 30) n++; colDark[x] = n > (H - 40) * 0.85; }
        for (int y = 0; y < H; y++) { int n = 0; for (int x = 0; x < W; x++) if (Lum(x, y) < 30) n++; rowDark[y] = n > W * 0.85; }
        var colRuns = Runs(colDark); var rowRuns = Runs(rowDark);
        // Cells are the gaps between consecutive border runs, keeping only big ones.
        var xs = new List<int[]>(); var ys = new List<int[]>();
        for (int i = 0; i + 1 < colRuns.Count; i++) { int a = colRuns[i][1] + 1, b = colRuns[i + 1][0] - 1; if (b - a > 150) xs.Add(new[] { a, b }); }
        for (int i = 0; i + 1 < rowRuns.Count; i++) { int a = rowRuns[i][1] + 1, b = rowRuns[i + 1][0] - 1; if (b - a > 150) ys.Add(new[] { a, b }); }
        if (xs.Count != 3 || ys.Count != 4) return "grid not found: " + xs.Count + " cols, " + ys.Count + " rows";

        int cw = int.MaxValue, ch = int.MaxValue;
        foreach (var c in xs) cw = Math.Min(cw, c[1] - c[0] + 1);
        foreach (var r in ys) ch = Math.Min(ch, r[1] - r[0] + 1);
        const int FS = 256;
        int offX = (FS - cw) / 2, offY = (FS - ch) / 2;

        var sheet = new Bitmap(FS * 4, FS * 4, PixelFormat.Format32bppArgb);
        var sd = sheet.LockBits(new Rectangle(0, 0, FS * 4, FS * 4), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var outPx = new int[FS * 4 * FS * 4];
        string report = "cells " + cw + "x" + ch + ":";

        int frame = 0;
        foreach (var r in ys) foreach (var c in xs) {
            int x0 = c[0], y0 = r[0];
            var water = new bool[cw * ch];
            var stack = new Stack<int>();
            for (int i = 0; i < cw; i++) { stack.Push(i); stack.Push((ch - 1) * cw + i); }
            for (int j = 0; j < ch; j++) { stack.Push(j * cw); stack.Push(j * cw + cw - 1); }
            while (stack.Count > 0) {
                int k = stack.Pop(); if (water[k]) continue;
                int lx = k % cw, ly = k / cw;
                if (!Water(x0 + lx, y0 + ly)) continue;
                water[k] = true;
                if (lx > 0) stack.Push(k - 1); if (lx < cw - 1) stack.Push(k + 1);
                if (ly > 0) stack.Push(k - cw); if (ly < ch - 1) stack.Push(k + cw);
            }
            // Largest 8-connected non-water blob = the shark.
            var label = new int[cw * ch]; int best = 0, bestN = 0, next = 0;
            for (int k = 0; k < cw * ch; k++) {
                if (water[k] || label[k] != 0) continue;
                next++; int n = 0; stack.Push(k); label[k] = next;
                while (stack.Count > 0) {
                    int q = stack.Pop(); n++; int qx = q % cw, qy = q / cw;
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                        int nx = qx + dx, ny = qy + dy;
                        if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
                        int nk = ny * cw + nx;
                        if (!water[nk] && label[nk] == 0) { label[nk] = next; stack.Push(nk); }
                    }
                }
                if (n > bestN) { bestN = n; best = next; }
            }
            int fx = (frame % 4) * FS + offX, fy = (frame / 4) * FS + offY;
            for (int ly = 0; ly < ch; ly++) for (int lx = 0; lx < cw; lx++) {
                if (label[ly * cw + lx] != best) continue;
                outPx[(fy + ly) * FS * 4 + fx + lx] = px[(y0 + ly) * W + x0 + lx] | unchecked((int)0xFF000000);
            }
            report += " " + bestN;
            frame++;
        }
        Marshal.Copy(outPx, 0, sd.Scan0, outPx.Length);
        sheet.UnlockBits(sd);
        sheet.Save(outPath, ImageFormat.Png);

        // Preview: all 12 on a dark grey and on a light background.
        var pv = new Bitmap(FS * 6, FS * 4);
        using (var g = Graphics.FromImage(pv)) {
            g.Clear(Color.FromArgb(60, 60, 60));
            g.FillRectangle(new SolidBrush(Color.FromArgb(225, 225, 210)), FS * 3, 0, FS * 3, FS * 4);
            for (int f = 0; f < 12; f++) {
                var srcR = new Rectangle((f % 4) * FS, (f / 4) * FS, FS, FS);
                g.DrawImage(sheet, new Rectangle((f % 3) * FS / 2, (f / 3) * FS, FS / 2, FS), srcR, GraphicsUnit.Pixel);
                g.DrawImage(sheet, new Rectangle(FS * 3 + (f % 3) * FS / 2, (f / 3) * FS, FS / 2, FS), srcR, GraphicsUnit.Pixel);
            }
        }
        pv.Save(previewPath, ImageFormat.Png);
        pv.Dispose(); sheet.Dispose();
        return report;
    }
}
'@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path (Resolve-Path $OutDir).Path 'shark_bite.png'
[SqShark]::Run((Resolve-Path $Source).Path, $out, $PreviewPath)
Write-Host ("wrote {0} ({1:N0} KB); preview {2}" -f $out, ((Get-Item $out).Length / 1KB), $PreviewPath)
