# Cuts the Sharks trail piece, Media\Cursor\shark.png, out of an AI-generated
# image the user supplied (2026-10-11, cleared to ship): a near-black great
# white in profile, facing right, on teal water with a wave pattern.
#
# Darkness becomes opacity -- the body solid, the gill slits and mouth line
# (lighter, mid-teal) partly see-through so they still read as detail, the
# water gone -- then only the largest solid blob (the shark) is kept, which
# drops any dark specks in the waves. The result is WHITE with that alpha, so
# the trail can tint it, cropped to the shark and fitted into 128 x 128,
# centred, facing RIGHT (Core/Cursor.lua mirrors it with the cursor).
#
# This replaced the hand-drawn GDI+ shark that make-cursor.ps1 used to make,
# which is why that script no longer writes shark.png.
#
#   powershell -ExecutionPolicy Bypass -File .claude\cut-shark-silhouette.ps1 -Source <image>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$OutPath
)
$ErrorActionPreference = 'Stop'
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot '..\Media\Cursor\shark.png' }
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SqSharkSil {
    public static string Run(string src, string outPath) {
        var bmp = new Bitmap(src);
        int W = bmp.Width, H = bmp.Height;
        var d = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new int[W * H];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        bmp.UnlockBits(d); bmp.Dispose();

        // Alpha from the green channel: shark ~5, gill lines ~50, water 80+.
        var alpha = new double[W * H];
        for (int i = 0; i < px.Length; i++) {
            int g = (px[i] >> 8) & 255;
            double a = (70.0 - g) / 55.0;
            alpha[i] = a < 0 ? 0 : (a > 1 ? 1 : a);
        }
        // Largest blob of solid pixels; keep alpha only on it and a 2 px
        // margin round it (so the anti-aliased edge survives).
        var label = new int[W * H]; int best = 0, bestN = 0, next = 0;
        var stack = new Stack<int>();
        for (int k = 0; k < px.Length; k++) {
            if (alpha[k] < 0.5 || label[k] != 0) continue;
            next++; int n = 0; label[k] = next; stack.Push(k);
            while (stack.Count > 0) {
                int q = stack.Pop(); n++; int qx = q % W, qy = q / W;
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    int nx = qx + dx, ny = qy + dy;
                    if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
                    int nk = ny * W + nx;
                    if (alpha[nk] >= 0.5 && label[nk] == 0) { label[nk] = next; stack.Push(nk); }
                }
            }
            if (n > bestN) { bestN = n; best = next; }
        }
        var keep = new bool[W * H];
        int minX = W, minY = H, maxX = -1, maxY = -1;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            if (label[y * W + x] != best) continue;
            for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
                int nx = x + dx, ny = y + dy;
                if (nx >= 0 && ny >= 0 && nx < W && ny < H) keep[ny * W + nx] = true;
            }
            if (x < minX) minX = x; if (x > maxX) maxX = x;
            if (y < minY) minY = y; if (y > maxY) maxY = y;
        }
        // The interior lines (gills, mouth) are not in the blob but are
        // inside its outline: keep alpha anywhere inside the bounding box
        // that is enclosed -- approximated by the dilated blob, widened
        // across each row between the blob's leftmost and rightmost pixels.
        for (int y = minY; y <= maxY; y++) {
            int l = -1, r = -1;
            for (int x = minX; x <= maxX; x++) if (label[y * W + x] == best) { if (l < 0) l = x; r = x; }
            if (l >= 0) for (int x = l; x <= r; x++) keep[y * W + x] = true;
        }

        minX = Math.Max(0, minX - 2); minY = Math.Max(0, minY - 2);
        maxX = Math.Min(W - 1, maxX + 2); maxY = Math.Min(H - 1, maxY + 2);
        int cw = maxX - minX + 1, ch = maxY - minY + 1;
        var crop = new Bitmap(cw, ch, PixelFormat.Format32bppArgb);
        var cd = crop.LockBits(new Rectangle(0, 0, cw, ch), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var cpx = new int[cw * ch];
        for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
            int k = (minY + y) * W + minX + x;
            int a = keep[k] ? (int)Math.Round(alpha[k] * 255) : 0;
            cpx[y * cw + x] = (a << 24) | 0xFFFFFF;
        }
        Marshal.Copy(cpx, 0, cd.Scan0, cpx.Length);
        crop.UnlockBits(cd);

        // Fit into 128 x 128, aspect kept, centred, 2 px margin.
        const int S = 128;
        double scale = Math.Min((S - 4.0) / cw, (S - 4.0) / ch);
        int ow = (int)Math.Round(cw * scale), oh = (int)Math.Round(ch * scale);
        var outBmp = new Bitmap(S, S, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(outBmp)) {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(crop, new Rectangle((S - ow) / 2, (S - oh) / 2, ow, oh));
        }
        outBmp.Save(outPath, ImageFormat.Png);
        outBmp.Dispose(); crop.Dispose();
        return "shark " + cw + "x" + ch + " -> " + ow + "x" + oh;
    }
}
'@

[SqSharkSil]::Run((Resolve-Path $Source).Path, [System.IO.Path]::GetFullPath($OutPath))
