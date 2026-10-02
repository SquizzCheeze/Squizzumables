# Generates the mouse cursor images in Media\Cursor (Core/Cursor.lua).
#
#   ring.png   a ring, white, transparent inside and out. Used three ways: the
#              plain ring around the cursor, and as the SWIPE texture of the GCD
#              and cast cooldowns, so their sweep is cut to the ring's shape.
#              Thickness is a fraction of the image, so it scales with the frame.
#   dot.png    a filled circle with an anti-aliased edge: the centre dot.
#   soft.png   a round radial falloff: one particle of the trail. Soft rather
#              than hard-edged so overlapping particles blend into a ribbon.
#   duck.png   a rubber-duck silhouette facing RIGHT, eye cut out: the Duck
#              trail style. Core/Cursor.lua mirrors it when the cursor moves left.
#
# Our own images, deliberately: Ultimate Mouse Cursor (what this replaces) ships
# no licence, so none of its art is reused.
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-cursor.ps1
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Cursor')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size = 128
$C = $Size / 2.0

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Per-pixel alpha from a function of the distance to the centre, supersampled
# 4x4 so edges are smooth. Colour is always white; WoW tints it.
function Write-Radial([string]$name, [scriptblock]$alphaAt) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $sum = 0.0
            for ($sy = 0; $sy -lt 4; $sy++) {
                for ($sx = 0; $sx -lt 4; $sx++) {
                    $dx = $x + ($sx + 0.5) / 4 - $C
                    $dy = $y + ($sy + 0.5) / 4 - $C
                    $sum += & $alphaAt ([Math]::Sqrt($dx * $dx + $dy * $dy))
                }
            }
            # 0.0 / 1.0, never 0 / 1: an integer literal makes PowerShell pick the
            # int overloads of Min/Max, which round every partial alpha to 0 or 1
            # (it silently turned the anti-aliasing and the soft falloff off).
            $a = [int][Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $sum / 16)) * 255)
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($a, 255, 255, 255))
        }
    }
    $path = Join-Path $OutDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "wrote $path"
}

$Outer = $C - 2      # leave a pixel or two for the edge
$Thick = 12          # ring thickness in pixels at 128

Write-Radial 'ring.png' { param($d) if ($d -le $Outer -and $d -ge $Outer - $Thick) { 1 } else { 0 } }
Write-Radial 'dot.png'  { param($d) if ($d -le $Outer) { 1 } else { 0 } }
# Smooth falloff: full at the centre, gone at the edge. 0.0, not 0: with an
# integer first argument PowerShell picks Math.Max(int, int) and rounds the
# falloff to a solid disc.
Write-Radial 'soft.png' { param($d) $t = [Math]::Max(0.0, 1.0 - $d / $Outer); $t * $t }

# The duck: plain GDI+ shapes, anti-aliased, unioned into one white fill.
function Write-Duck {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

    $g.FillEllipse($white, 14, 58, 96, 50)          # body
    $g.FillEllipse($white, 66, 40, 34, 42)          # neck, joining head to body
    $g.FillEllipse($white, 66, 16, 44, 44)          # head
    # tail, a point rising off the back of the body
    $tail = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF 4, 50),
        (New-Object System.Drawing.PointF 34, 66),
        (New-Object System.Drawing.PointF 20, 86))
    $g.FillPolygon($white, $tail)
    # beak
    $beak = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF 104, 32),
        (New-Object System.Drawing.PointF 126, 40),
        (New-Object System.Drawing.PointF 104, 48))
    $g.FillPolygon($white, $beak)

    # The eye, punched out so the silhouette still reads as a duck when solid.
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $clear = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    $g.FillEllipse($clear, 89, 28, 8, 8)

    $g.Dispose()
    $path = Join-Path $OutDir 'duck.png'
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "wrote $path"
}
Write-Duck
