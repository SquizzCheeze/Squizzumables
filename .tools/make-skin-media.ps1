# Generates the skins' own art in Media\Skins (our own drawings, not ElvUI's):
#
#   arrow.png   64x64 white chevron pointing UP (rotate for the others)
#   close.png   64x64 white cross
#   shadow.png  64x64 soft dark edge with a clear middle, drawn as a 9-slice
#               (Texture:SetTextureSliceMargins 24 on every side) laid OUTSIDE
#               a frame for the drop shadow
#
#   powershell -ExecutionPolicy Bypass -File .tools\make-skin-media.ps1
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Skins')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

function New-Canvas([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    return $bmp, $g
}

# Arrow: a thick chevron, round caps.
$bmp, $g = New-Canvas 64
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 9
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$pts = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF 14, 42),
    (New-Object System.Drawing.PointF 32, 22),
    (New-Object System.Drawing.PointF 50, 42))
$g.DrawLines($pen, $pts)
$bmp.Save((Join-Path $OutDir 'arrow.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# Close: two strokes.
$bmp, $g = New-Canvas 64
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 8
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($pen, 18, 18, 46, 46)
$g.DrawLine($pen, 46, 18, 18, 46)
$bmp.Save((Join-Path $OutDir 'close.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# Shadow: alpha falls off with distance outside a 16px-inset rectangle,
# fully clear inside it (the frame covers that part anyway).
$S = 64; $M = 24
$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
for ($y = 0; $y -lt $S; $y++) {
    for ($x = 0; $x -lt $S; $x++) {
        $dx = [Math]::Max(0, [Math]::Max($M - $x - 0.5, $x + 0.5 - ($S - $M)))
        $dy = [Math]::Max(0, [Math]::Max($M - $y - 0.5, $y + 0.5 - ($S - $M)))
        $d = [Math]::Sqrt($dx * $dx + $dy * $dy) / $M
        $a = 0
        if ($dx -gt 0 -or $dy -gt 0) { $a = [Math]::Max(0, 1 - $d); $a = $a * $a }
        $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb([int](255 * $a), 0, 0, 0))
    }
}
$bmp.Save((Join-Path $OutDir 'shadow.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $OutDir"
