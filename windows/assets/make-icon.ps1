# Draws keybridge.ico (a keyboard with a blue mouse), the icon of the KeyBridge shortcut.
# Only needed to change the icon: powershell -ExecutionPolicy Bypass -File make-icon.ps1
Add-Type -AssemblyName System.Drawing
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min(2 * $r, [Math]::Min($w, $h))
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}

function Draw([int]$s) {
    $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $g.ScaleTransform($s / 256.0, $s / 256.0)              # draw on a 256x256 canvas
    $body = [Drawing.Color]::FromArgb(255, 38, 50, 56)      # keyboard: dark slate
    $key  = [Drawing.Color]::FromArgb(255, 236, 239, 241)
    $blue = [Drawing.Color]::FromArgb(255, 30, 136, 229)    # mouse: Bluetooth blue

    $g.FillPath((New-Object Drawing.SolidBrush $body), (RoundRect 4 98 196 132 22))
    $kb = New-Object Drawing.SolidBrush $key
    foreach ($row in 0..2) {
        foreach ($col in 0..5) { $g.FillPath($kb, (RoundRect (20 + $col * 28) (114 + $row * 28) 22 22 5)) }
    }
    $g.FillPath($kb, (RoundRect 48 198 110 18 5))           # space bar

    $mouse = RoundRect 160 14 88 136 44
    $g.DrawPath((New-Object Drawing.Pen ([Drawing.Color]::White), 10), $mouse)   # separates it from the keyboard
    $g.FillPath((New-Object Drawing.SolidBrush $blue), $mouse)
    $light = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 187, 222, 251)), 5
    $g.DrawLine($light, 204, 18, 204, 66)                   # split between the buttons
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::White)), (RoundRect 197 34 14 26 7))   # wheel
    $g.Dispose(); return $bmp
}

# Every size as a classic 32-bit DIB: the .NET Framework C# compiler rejects PNG-compressed icon entries.
function DibBytes($bmp) {
    $s = $bmp.Width
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
    $maskRow = [int][Math]::Ceiling($s / 32.0) * 4
    $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]0); $w.Write([int]($s * $s * 4 + $maskRow * $s)); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    $data = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $s, $s), 'ReadOnly', ([Drawing.Imaging.PixelFormat]::Format32bppArgb))
    $row = New-Object byte[] ($s * 4)
    for ($y = $s - 1; $y -ge 0; $y--) {                     # bottom-up rows, BGRA
        [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $row.Length)
        $w.Write($row)
    }
    $bmp.UnlockBits($data)
    $w.Write((New-Object byte[] ($maskRow * $s)))           # AND mask unused (alpha channel does it)
    $w.Flush(); return , $ms.ToArray()                      # leading comma: keep it one byte[]
}

$sizes = 16, 24, 32, 48, 64, 256
$images = foreach ($s in $sizes) { , (DibBytes (Draw $s)) }
$out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $out
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $b = [byte]($sizes[$i] % 256)                            # 0 means 256
    $w.Write($b); $w.Write($b); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$images[$i].Length); $w.Write([int]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write([byte[]]$img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $Here 'keybridge.ico'), $out.ToArray())
Write-Host "Wrote keybridge.ico"
