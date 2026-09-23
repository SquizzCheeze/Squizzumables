# Generates the Cooldown Manager icon-shape images in Media\Shapes.
#
# Four images per shape:
#
#   <name>.png             the shape itself. ONE image doing three jobs in
#                          Squizzumables_CDM.lua (ApplyIconShape): the icon's
#                          mask, the cooldown's swipe texture, and the border --
#                          the same shape drawn behind the icon, larger by the
#                          border thickness and tinted. So it has to fill its
#                          square edge to edge and be centred, or the rim comes
#                          out lopsided.
#
#   <name>_proc_start.png  the proc glow, as flipbook sheets that replace the
#   <name>_proc_loop.png   art in Blizzard's own alert (UI/Glow.lua,
#                          ApplyAlertArt). Blizzard's grid exactly: 30 frames,
#                          6 rows of 5, row-major. Start is the one-shot burst
#                          (0.7s): a flash over the icon and a ring settling
#                          onto its edge. Loop (1s, repeating) is a breathing
#                          halo with two bright sparks running round the
#                          outline half a lap apart, each moving half a lap per
#                          loop, so the last frame hands over to the first
#                          without a jump.
#
#   <name>_glow.png        a static halo: the fallback for when Blizzard's
#                          alert is unavailable, pulsed by our own animation.
#
# In every glow image the shape sits at 1/GlowScale of the frame, because the
# frame is drawn GlowScale times the icon's size (Blizzard's alert is 1.4x the
# button; Glow.lua's SHAPED_SCALE for the halo). That is what puts the glow's
# outline on the icon's edge.
#
# White where drawn, transparent outside, anti-aliased in the alpha channel
# only; the addon tints them. RGB stays white wherever alpha is non-zero, so a
# tint gets no dark fringe, and black where alpha is zero, so an image still
# masks correctly if a mask is ever read by colour, not alpha.
#
#   powershell -ExecutionPolicy Bypass -File .claude\make-shapes.ps1 [-SheetPath preview.png] [-FramesPath frames.png]
#
# -SheetPath writes a preview of the shapes, borders and halos. -FramesPath
# writes one of the proc animation: each shape over a blue "icon", start
# frames on the left and loop frames on the right.
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Shapes'),
    [string]$SheetPath,
    [string]$FramesPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size      = 128
$Pad       = 2.0    # room for the anti-aliased edge
$GlowScale = 1.4    # must equal SHAPED_SCALE in UI/Glow.lua

# Flipbook sheets. Frame size, grid and frame count must equal SHEET_FRAME,
# SHEET_ROWS, SHEET_COLS and SHEET_FRAMES in UI/Glow.lua. 84px frames on a 512
# sheet is Masque's layout for the same job: 5x84 = 420 wide, 6x84 = 504 tall.
$SheetFrame  = 84
$SheetCols   = 5
$SheetRows   = 6
$SheetFrames = 30
$SheetSize   = 512

function PF([double]$x, [double]$y) {
    New-Object System.Drawing.PointF ([single]$x), ([single]$y)
}

function Polygon([System.Drawing.PointF[]]$pts) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddPolygon($pts)
    $p
}

# $points vertices on the outer radius, alternating with as many on the inner
# radius when $rInner is non-zero. The first vertex points straight up.
function Radial([int]$points, [double]$rOuter, [double]$rInner) {
    $list  = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    $steps = if ($rInner) { $points * 2 } else { $points }
    for ($i = 0; $i -lt $steps; $i++) {
        $r = if ($rInner -and ($i % 2)) { $rInner } else { $rOuter }
        $a = -[Math]::PI / 2 + $i * 2 * [Math]::PI / $steps
        $list.Add((PF ($r * [Math]::Cos($a)) ($r * [Math]::Sin($a))))
    }
    $list.ToArray()
}

# A copy of the path, scaled to fit a $box-sized square (aspect kept) and
# centred on ($cx, $cy). A copy because each image needs its own size.
function Fit([System.Drawing.Drawing2D.GraphicsPath]$src, [double]$box, [double]$cx, [double]$cy) {
    $path = $src.Clone()
    $b = $path.GetBounds()
    $scale = [Math]::Min($box / $b.Width, $box / $b.Height)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    # Matrix calls prepend, so these apply bottom-up: centre on the origin,
    # scale, then move into place.
    $m.Translate($cx, $cy)
    $m.Scale($scale, $scale)
    $m.Translate(-($b.X + $b.Width / 2), -($b.Y + $b.Height / 2))
    $path.Transform($m)
    $path
}

function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    return @{ Bitmap = $bmp; Graphics = $g }
}

# White wherever anything was drawn, black where nothing was; alpha untouched.
function Finish($canvas) {
    $canvas.Graphics.Dispose()
    $bmp   = $canvas.Bitmap
    $rect  = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data  = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, $bmp.PixelFormat)
    $n     = $data.Stride * $bmp.Height
    $bytes = New-Object byte[] $n
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $n)
    for ($i = 0; $i -lt $n; $i += 4) {
        $v = if ($bytes[$i + 3] -gt 0) { 255 } else { 0 }
        $bytes[$i] = $v; $bytes[$i + 1] = $v; $bytes[$i + 2] = $v
    }
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $n)
    $bmp.UnlockBits($data)
    $bmp
}

function Stroke($g, $path, [double]$alpha, [double]$width) {
    $a = [int][Math]::Max(0, [Math]::Min(255, $alpha))
    if ($a -le 0) { return }
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($a, 255, 255, 255)), ([single]$width)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $path)
    $pen.Dispose()
}

function Fill($g, $path, [double]$alpha) {
    $a = [int][Math]::Max(0, [Math]::Min(255, $alpha))
    if ($a -le 0) { return }
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, 255, 255, 255))
    $g.FillPath($brush, $path)
    $brush.Dispose()
}

# A soft halo on the outline: stroked wide and faint, then narrower, so the
# alpha builds towards the edge the way a blur would (GDI+ has no blur), then
# one crisp line on the edge itself. Half of every stroke falls inside the
# shape, which gives the inner glow over the icon's rim that Blizzard's own
# alert has. $widest must stay inside the frame's margin.
function Halo($g, $path, [double]$widest, [double]$step, [double]$softAlpha, [double]$lineAlpha, [double]$lineWidth) {
    for ($w = $widest; $w -ge $step; $w -= $step) { Stroke $g $path $softAlpha $w }
    Stroke $g $path $lineAlpha $lineWidth
}

# ---------------------------------------------------------------------------
# Walking the outline, for the sparks.
# ---------------------------------------------------------------------------
function Get-Outline([System.Drawing.Drawing2D.GraphicsPath]$path) {
    $flat = $path.Clone()
    $flat.Flatten((New-Object System.Drawing.Drawing2D.Matrix), 0.25)
    $pts = $flat.PathPoints
    $cum = New-Object double[] ($pts.Length + 1)
    for ($i = 0; $i -lt $pts.Length; $i++) {
        $a = $pts[$i]; $b = $pts[($i + 1) % $pts.Length]
        $dx = $b.X - $a.X; $dy = $b.Y - $a.Y
        $cum[$i + 1] = $cum[$i] + [Math]::Sqrt($dx * $dx + $dy * $dy)
    }
    return @{ Points = $pts; Cum = $cum; Length = $cum[$pts.Length] }
}

function PointAt($o, [double]$d) {
    $len = $o.Length
    $d = $d % $len
    if ($d -lt 0) { $d += $len }
    $pts = $o.Points; $cum = $o.Cum
    for ($i = 0; $i -lt $pts.Length; $i++) {
        if ($cum[$i + 1] -ge $d) {
            $seg = $cum[$i + 1] - $cum[$i]
            $f = if ($seg -gt 0) { ($d - $cum[$i]) / $seg } else { 0 }
            $a = $pts[$i]; $b = $pts[($i + 1) % $pts.Length]
            return (PF ($a.X + ($b.X - $a.X) * $f) ($a.Y + ($b.Y - $a.Y) * $f))
        }
    }
    $pts[0]
}

# A bright spark with a fading tail, following the outline backwards from
# $head for $tail pixels. Layered widths again stand in for a blur.
$SparkLayers = @(@(9.0, 30), @(5.0, 70), @(2.2, 255))
function Draw-Spark($g, $o, [double]$head, [double]$tail) {
    $n = 16
    $prev = PointAt $o ($head - $tail)
    for ($i = 1; $i -le $n; $i++) {
        $f  = $i / $n                     # 0 at the end of the tail, 1 at the head
        $pt = PointAt $o ($head - $tail * (1 - $f))
        foreach ($layer in $SparkLayers) {
            $a = [int][Math]::Min(255, $layer[1] * $f * $f)
            if ($a -gt 0) {
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($a, 255, 255, 255)), ([single]$layer[0])
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawLine($pen, $prev, $pt)
                $pen.Dispose()
            }
        }
        $prev = $pt
    }
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
function Render-Fill([System.Drawing.Drawing2D.GraphicsPath]$src) {
    $c = New-Canvas $Size $Size
    $path = Fit $src ($Size - 2 * $Pad) ($Size / 2) ($Size / 2)
    $c.Graphics.FillPath([System.Drawing.Brushes]::White, $path)
    Finish $c
}

# The static fallback halo. At 128px and GlowScale 1.4 the margin is ~18px a
# side, and half of the widest stroke (22) is 11.
function Render-Glow([System.Drawing.Drawing2D.GraphicsPath]$src) {
    $c = New-Canvas $Size $Size
    $path = Fit $src ($Size / $GlowScale) ($Size / 2) ($Size / 2)
    Halo $c.Graphics $path 22 2 22 230 2.5
    Finish $c
}

# Sheet cell $k's top-left corner.
function CellOrigin([int]$k) {
    return @((($k % $SheetCols) * $SheetFrame), ([Math]::Floor($k / $SheetCols) * $SheetFrame))
}

# Draws $k into its cell with the origin moved to the cell's corner and a clip
# so nothing bleeds into the neighbouring frame.
function Begin-Cell($g, [int]$k) {
    $o = CellOrigin $k
    $g.ResetTransform()
    $g.ResetClip()
    $g.TranslateTransform([single]$o[0], [single]$o[1])
    $g.SetClip((New-Object System.Drawing.RectangleF 0, 0, ([single]$SheetFrame), ([single]$SheetFrame)))
}

# Margin at 84px and GlowScale 1.4: 12px a side. The base halo's widest
# stroke is 14 (7 either side); a spark's is 9.
function Render-LoopSheet([System.Drawing.Drawing2D.GraphicsPath]$src) {
    $c = New-Canvas $SheetSize $SheetSize
    $g = $c.Graphics
    $mid  = $SheetFrame / 2
    $path = Fit $src ($SheetFrame / $GlowScale) $mid $mid
    $o    = Get-Outline $path
    for ($k = 0; $k -lt $SheetFrames; $k++) {
        Begin-Cell $g $k
        $phase  = $k / $SheetFrames
        $breath = 0.85 + 0.15 * [Math]::Sin(2 * [Math]::PI * $phase)
        Halo $g $path 14 2 (20 * $breath) (140 * $breath) 1.8
        for ($s = 0; $s -lt 2; $s++) {
            Draw-Spark $g $o (($phase * 0.5 + $s * 0.5) * $o.Length) ($o.Length * 0.22)
        }
    }
    $g.ResetTransform(); $g.ResetClip()
    Finish $c
}

# The burst: starts 10% oversized, bright and wide with a flash over the icon,
# and eases onto the loop's resting halo by the last frame, so the hand-over
# to the loop is continuous. Worst case at frame 0: half of 66 plus half of
# 17.5 is ~42, just inside the 42px half-frame.
function Render-StartSheet([System.Drawing.Drawing2D.GraphicsPath]$src) {
    $c = New-Canvas $SheetSize $SheetSize
    $g = $c.Graphics
    $mid = $SheetFrame / 2
    for ($k = 0; $k -lt $SheetFrames; $k++) {
        Begin-Cell $g $k
        $p     = $k / ($SheetFrames - 1)
        $ease  = 1 - [Math]::Pow(1 - $p, 3)
        $left  = 1 - $ease
        $path  = Fit $src (($SheetFrame / $GlowScale) * (1 + 0.10 * $left)) $mid $mid
        Fill $g $path (150 * [Math]::Pow(1 - $p, 2.5))
        Halo $g $path (14 * (1 + 0.25 * $left)) (2 * (1 + 0.25 * $left)) (20 * (1 + 1.5 * $left)) (140 + 115 * $left) 1.8
    }
    $g.ResetTransform(); $g.ResetClip()
    Finish $c
}

function Tint($r, $gr, $b) {
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = $r; $cm.Matrix11 = $gr; $cm.Matrix22 = $b
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $ia
}

function Draw-Tinted($g, $img, $x, $y, $s, $r, $gr, $b) {
    $dest = New-Object System.Drawing.Rectangle ([int]$x), ([int]$y), ([int]$s), ([int]$s)
    $g.DrawImage($img, $dest, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, (Tint $r $gr $b))
}

function Draw-TintedCell($g, $img, [int]$k, $x, $y, $r, $gr, $b) {
    $o = CellOrigin $k
    $dest = New-Object System.Drawing.Rectangle ([int]$x), ([int]$y), $SheetFrame, $SheetFrame
    $g.DrawImage($img, $dest, [int]$o[0], [int]$o[1], $SheetFrame, $SheetFrame, [System.Drawing.GraphicsUnit]::Pixel, (Tint $r $gr $b))
}

# ---------------------------------------------------------------------------
# The shapes. Units are arbitrary; Fit scales each to the image.
# ---------------------------------------------------------------------------
$shapes = [ordered]@{}

$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddEllipse(0, 0, 100, 100)
$shapes['circle'] = $p

$shapes['diamond'] = Polygon @((PF 50 0), (PF 100 50), (PF 50 100), (PF 0 50))

# Point-up, so it fills the height and the icon keeps its middle.
$shapes['hexagon'] = Polygon (Radial 6 50 0)

# Fatter than a true pentagram (inner/outer 0.38) so the icon survives the cut.
$shapes['star'] = Polygon (Radial 5 50 25)

# Heater shield: flat top, straight sides, curving in to a point.
$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddLine(0, 0, 100, 0)
$p.AddLine(100, 0, 100, 50)
$p.AddBezier(100, 50, 100, 85, 75, 102, 50, 118)
$p.AddBezier(50, 118, 25, 102, 0, 85, 0, 50)
$p.CloseFigure()
$shapes['shield'] = $p

# Square, for the glow art only -- a square icon needs no mask, no shaped swipe
# and no border image, so square.png goes unused (UI/Shapes.lua keeps square out
# of FILE and points only SQUARE_GLOW at these). Its proc glow is generated all
# the same, so every shape's proc glow is ours and therefore tintable, rather
# than square alone being stuck with Blizzard's gold art.
#
# Corners rounded very slightly (4 of 100): a razor-sharp corner makes the
# halo's layered strokes collide into a bright spike, and an icon's own art has
# a soft corner anyway.
$r = 4.0
$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
$p.AddArc((100 - 2 * $r), 0, 2 * $r, 2 * $r, 270, 90)
$p.AddArc((100 - 2 * $r), (100 - 2 * $r), 2 * $r, 2 * $r, 0, 90)
$p.AddArc(0, (100 - 2 * $r), 2 * $r, 2 * $r, 90, 90)
$p.CloseFigure()
$shapes['square'] = $p

# The classic parametric heart, y flipped so the point is at the bottom.
$pts = for ($i = 0; $i -lt 240; $i++) {
    $t = 2 * [Math]::PI * $i / 240
    $x = 16 * [Math]::Pow([Math]::Sin($t), 3)
    $y = -(13 * [Math]::Cos($t) - 5 * [Math]::Cos(2 * $t) - 2 * [Math]::Cos(3 * $t) - [Math]::Cos(4 * $t))
    PF $x $y
}
$shapes['heart'] = Polygon $pts

# ---------------------------------------------------------------------------
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null

$fills  = [ordered]@{}
$glows  = [ordered]@{}
$starts = [ordered]@{}
$loops  = [ordered]@{}
foreach ($name in $shapes.Keys) {
    $fills[$name]  = Render-Fill $shapes[$name]
    $glows[$name]  = Render-Glow $shapes[$name]
    $starts[$name] = Render-StartSheet $shapes[$name]
    $loops[$name]  = Render-LoopSheet $shapes[$name]
    $png = [System.Drawing.Imaging.ImageFormat]::Png
    $fills[$name].Save((Join-Path $OutDir "$name.png"), $png)
    $glows[$name].Save((Join-Path $OutDir "${name}_glow.png"), $png)
    $starts[$name].Save((Join-Path $OutDir "${name}_proc_start.png"), $png)
    $loops[$name].Save((Join-Path $OutDir "${name}_proc_loop.png"), $png)
    Write-Output "wrote $name (shape, glow, proc start, proc loop)"
}

if ($SheetPath) {
    $cell  = 150
    $sheet = New-Object System.Drawing.Bitmap ($cell * $fills.Count), ($cell * 3)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 40, 40, 40))
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $i = 0
    foreach ($name in $fills.Keys) {
        $fill = $fills[$name]
        $x = $i * $cell + ($cell - $Size) / 2
        $g.DrawImage($fill, [int]$x, 11, $Size, $Size)
        $inset = 8
        Draw-Tinted $g $fill $x ($cell + 11) $Size 1.0 0.8 0.1
        Draw-Tinted $g $fill ($x + $inset) ($cell + 11 + $inset) ($Size - 2 * $inset) 0.2 0.5 1.0
        $icon = [int]($Size / $GlowScale)
        Draw-Tinted $g $fill ($i * $cell + ($cell - $icon) / 2) (2 * $cell + ($cell - $icon) / 2) $icon 0.2 0.5 1.0
        Draw-Tinted $g $glows[$name] $x (2 * $cell + ($cell - $Size) / 2) $Size 1.0 0.82 0.0
        $i++
    }
    $g.Dispose()
    $sheet.Save([System.IO.Path]::GetFullPath($SheetPath), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "wrote $SheetPath"
}

if ($FramesPath) {
    $startPicks = @(0, 5, 10, 16, 22, 29)
    $loopPicks  = @(0, 5, 10, 15, 20, 25)
    $cols = $startPicks.Count + $loopPicks.Count
    $gap  = 16
    $w = $SheetFrame * $cols + $gap
    $h = $SheetFrame * $fills.Count
    $img = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($img)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 40, 40, 40))
    $icon = [int]($SheetFrame / $GlowScale)
    $row = 0
    foreach ($name in $fills.Keys) {
        $y = $row * $SheetFrame
        for ($j = 0; $j -lt $cols; $j++) {
            $x = $j * $SheetFrame + $(if ($j -ge $startPicks.Count) { $gap } else { 0 })
            Draw-Tinted $g $fills[$name] ($x + ($SheetFrame - $icon) / 2) ($y + ($SheetFrame - $icon) / 2) $icon 0.2 0.5 1.0
            if ($j -lt $startPicks.Count) {
                Draw-TintedCell $g $starts[$name] $startPicks[$j] $x $y 1.0 0.82 0.0
            } else {
                Draw-TintedCell $g $loops[$name] $loopPicks[$j - $startPicks.Count] $x $y 1.0 0.82 0.0
            }
        }
        $row++
    }
    $g.Dispose()
    $img.Save([System.IO.Path]::GetFullPath($FramesPath), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "wrote $FramesPath"
}
