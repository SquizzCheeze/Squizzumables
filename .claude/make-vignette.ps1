# Generates Media\Alerts\vignette.png: a screen-edge glow for the Kelerts buff
# images (Squizzumables_SpellAlerts.lua). White, so the alert's colour tints it;
# opaque at the very edge and fading to nothing a quarter of the way in, with
# rounded corners. It is stretched over the whole screen, which a smooth
# gradient survives at 256 px.
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-vignette.ps1
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Alerts')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size = 256
$Edge = 0.25      # how far in the glow reaches, as a fraction of the image

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
for ($y = 0; $y -lt $Size; $y++) {
    for ($x = 0; $x -lt $Size; $x++) {
        # Distance in from the nearest horizontal and vertical edge, 0..0.5.
        $u = [Math]::Min(($x + 0.5) / $Size, 1.0 - ($x + 0.5) / $Size)
        $v = [Math]::Min(($y + 0.5) / $Size, 1.0 - ($y + 0.5) / $Size)
        # Combined so the corners round off instead of meeting at a sharp mitre.
        $du = [Math]::Max(0.0, $Edge - $u)
        $dv = [Math]::Max(0.0, $Edge - $v)
        $t = [Math]::Min(1.0, [Math]::Sqrt($du * $du + $dv * $dv) / $Edge)
        # Eased, so it fades softly into the middle of the screen.
        $a = [int][Math]::Round($t * $t * 255)
        $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($a, 255, 255, 255))
    }
}
$path = Join-Path $OutDir 'vignette.png'
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "wrote $path"
