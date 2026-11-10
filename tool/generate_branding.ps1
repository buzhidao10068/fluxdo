# 从统一的节点图形生成 SVG、Android 矢量及各平台图标，不依赖额外图形工具。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$brandingRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nodePath = 'M320 704V320L704 704V320'
$nodeCircles = '<circle cx="320" cy="704" r="64"/><circle cx="320" cy="320" r="64"/><circle cx="704" cy="704" r="64"/><circle cx="704" cy="320" r="64"/>'

foreach ($variant in @('logo', 'logo_modern', 'logo_modern_light')) {
    $light = $variant.EndsWith('_light')
    $background = if ($light) { '#F0FDFA' } else { '#142A38' }
    $foreground = if ($light) { '#142A38' } else { '#F0FDFA' }
    $accent = if ($light) { '#0F766E' } else { '#2DD4BF' }
    $svg = @"
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <title>FluxDO NodeLoc unofficial client</title>
  <rect width="1024" height="1024" rx="224" fill="$background"/>
  <path d="$nodePath" fill="none" stroke="$foreground" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>
  <g fill="$accent">$nodeCircles</g>
</svg>
"@
    [System.IO.File]::WriteAllText((Join-Path $brandingRoot "assets/$variant.svg"), $svg + "`n", $utf8)
}

function New-BrandPng([int]$Width, [int]$Height, [bool]$Light) {
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml($(if ($Light) { '#F0FDFA' } else { '#142A38' })))
    $scale = [Math]::Min($Width, $Height) / 1024.0
    $graphics.TranslateTransform([single](($Width - 1024 * $scale) / 2), [single](($Height - 1024 * $scale) / 2))
    $graphics.ScaleTransform([single]$scale, [single]$scale)
    $pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml($(if ($Light) { '#142A38' } else { '#F0FDFA' })), 64)
    $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $points = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(320, 704), [System.Drawing.PointF]::new(320, 320),
        [System.Drawing.PointF]::new(704, 704), [System.Drawing.PointF]::new(704, 320)
    )
    $graphics.DrawLines($pen, $points)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($(if ($Light) { '#0F766E' } else { '#2DD4BF' })))
    foreach ($point in $points) { $graphics.FillEllipse($brush, $point.X - 64, $point.Y - 64, 128, 128) }
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose()
    $brush.Dispose()
    $pen.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    return ,$bytes
}

# 保持已有资源尺寸与资源目录结构；所有像素均从上方几何图形重新绘制。
$iconDirs = @('android/app/src/main/res', 'ios/Runner/Assets.xcassets', 'macos/Runner/Assets.xcassets', 'flatpak/icons', 'web/icons')
$rasterFiles = @(
    foreach ($relative in $iconDirs) { Get-ChildItem -LiteralPath (Join-Path $brandingRoot $relative) -Filter '*.png' -Recurse }
    Get-ChildItem -LiteralPath (Join-Path $brandingRoot 'assets/images') -Filter 'icon_*_preview.png'
    Get-Item -LiteralPath (Join-Path $brandingRoot 'web/favicon.png')
)
foreach ($file in $rasterFiles) {
    $image = [System.Drawing.Image]::FromFile($file.FullName)
    $width = $image.Width
    $height = $image.Height
    $image.Dispose()
    $light = $file.Name -match 'Light|light' -and $file.Name -notmatch 'Dark|dark'
    [System.IO.File]::WriteAllBytes($file.FullName, (New-BrandPng $width $height $light))
}

$icoStream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($icoStream)
$sizes = @(16, 32, 48, 64, 128, 256)
$pngs = @(foreach ($size in $sizes) { ,(New-BrandPng $size $size $false) })
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($index = 0; $index -lt $sizes.Count; $index++) {
    $encodedSize = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
    $writer.Write([byte]$encodedSize)
    $writer.Write([byte]$encodedSize)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$pngs[$index].Length)
    $writer.Write([uint32]$offset)
    $offset += $pngs[$index].Length
}
foreach ($png in $pngs) { $writer.Write([byte[]]$png) }
[System.IO.File]::WriteAllBytes((Join-Path $brandingRoot 'windows/runner/resources/app_icon.ico'), $icoStream.ToArray())
$writer.Dispose()
$icoStream.Dispose()

$vectorFiles = Get-ChildItem -LiteralPath (Join-Path $brandingRoot 'android/app/src/main/res') -Filter 'ic_launcher*.xml' -Recurse |
    Where-Object { $_.Directory.Name -in @('drawable', 'drawable-night') }
foreach ($file in $vectorFiles) {
    $monochrome = $file.Name.Contains('monochrome')
    $light = $file.Name.Contains('light')
    $foreground = if ($monochrome -or $light) { '#142A38' } else { '#F0FDFA' }
    $accent = if ($monochrome) { $foreground } elseif ($light) { '#0F766E' } else { '#2DD4BF' }
    $xml = @"
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="1024dp" android:height="1024dp" android:viewportWidth="1024" android:viewportHeight="1024">
  <group android:scaleX="0.65" android:scaleY="0.65" android:pivotX="512" android:pivotY="512">
    <path android:pathData="$nodePath" android:strokeColor="$foreground" android:strokeWidth="64" android:strokeLineCap="round" android:strokeLineJoin="round" android:fillColor="#00000000"/>
    <path android:fillColor="$accent" android:pathData="M256,704a64,64 0,1 0,128 0a64,64 0,1 0,-128 0 M256,320a64,64 0,1 0,128 0a64,64 0,1 0,-128 0 M640,704a64,64 0,1 0,128 0a64,64 0,1 0,-128 0 M640,320a64,64 0,1 0,128 0a64,64 0,1 0,-128 0"/>
  </group>
</vector>
"@
    [System.IO.File]::WriteAllText($file.FullName, $xml + "`n", $utf8)
}
Write-Output "已生成统一品牌图标：$($rasterFiles.Count) 个 PNG、Windows ICO、SVG 与 Android 矢量。"
