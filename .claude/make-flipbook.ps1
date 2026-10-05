# Packs a numbered image sequence (name_001.png, name_002.png, ...) into ONE
# flipbook sheet for the Kelerts buff images, and prints the values to type
# into the buff image editor (Frames, Cols, Rows, Frame W, Frame H).
#
# Why a sheet: a buff image is drawn on a button the game's aura engine owns,
# and nothing on that button may be changed after it is built -- so the lust
# alert's way of animating (loading the next numbered file every frame) cannot
# be used. A flipbook sheet is set up once and played by the game itself.
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-flipbook.ps1 -Name duckrun
#
# Reads Media\<Name>_NNN.png (from 001 up, until one is missing) and writes
# Media\<Name>_sheet.png. Frames are laid out row by row from the top-left;
# the sheet is padded to power-of-two dimensions (the frame size stays exact,
# which is what the editor's Frame W / Frame H are for).
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$MediaDir = (Join-Path $PSScriptRoot '..\Media'),
    [int]$Columns = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$files = @()
for ($i = 1; ; $i++) {
    $p = Join-Path $MediaDir ("{0}_{1:D3}.png" -f $Name, $i)
    if (-not (Test-Path $p)) { break }
    $files += $p
}
if ($files.Count -lt 2) { throw "Found $($files.Count) frame(s) named ${Name}_001.png...; need at least 2." }

$first = [System.Drawing.Image]::FromFile($files[0])
$fw, $fh = $first.Width, $first.Height
$first.Dispose()

$n = $files.Count
$cols = if ($Columns -gt 0) { $Columns } else { [int][Math]::Ceiling([Math]::Sqrt($n)) }
$rows = [int][Math]::Ceiling($n / $cols)

function Pow2([int]$v) { $p = 1; while ($p -lt $v) { $p *= 2 }; $p }
$sw, $sh = (Pow2 ($cols * $fw)), (Pow2 ($rows * $fh))
if ($sw -gt 4096 -or $sh -gt 4096) {
    Write-Warning "The sheet would be ${sw}x${sh}; over 4096 is likely too big for the game. Use smaller frames or fewer of them."
}

$sheet = New-Object System.Drawing.Bitmap $sw, $sh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::Transparent)
for ($i = 0; $i -lt $n; $i++) {
    $img = [System.Drawing.Image]::FromFile($files[$i])
    $x = ($i % $cols) * $fw
    $y = [Math]::Floor($i / $cols) * $fh
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle $x, $y, $fw, $fh))
    $img.Dispose()
}
$g.Dispose()
$out = Join-Path $MediaDir ("{0}_sheet.png" -f $Name)
$sheet.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()

Write-Host "wrote $out (${sw}x${sh})"
Write-Host ""
Write-Host "In the buff image editor, choose Your own texture and enter:"
Write-Host "  Texture:  ${Name}_sheet.png"
Write-Host "  Frames:   $n"
Write-Host "  Cols:     $cols"
Write-Host "  Rows:     $rows"
Write-Host "  Frame W:  $fw"
Write-Host "  H:        $fh"
