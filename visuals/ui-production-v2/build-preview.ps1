[CmdletBinding()]
param(
	[string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path -LiteralPath $Root).Path

Add-Type -AssemblyName System.Drawing

$assets = Join-Path $Root 'assets'
$previews = Join-Path $Root 'previews'
[System.IO.Directory]::CreateDirectory($previews) | Out-Null
$outputPath = Join-Path $previews 'main-menu-v2-preview.png'

function Draw-CenteredText {
	param(
		[System.Drawing.Graphics]$Graphics,
		[string]$Text,
		[System.Drawing.Font]$Font,
		[System.Drawing.Brush]$Brush,
		[System.Drawing.RectangleF]$Bounds
	)

	$format = [System.Drawing.StringFormat]::new()
	$format.Alignment = [System.Drawing.StringAlignment]::Center
	$format.LineAlignment = [System.Drawing.StringAlignment]::Center
	$format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
	$Graphics.DrawString($Text, $Font, $Brush, $Bounds, $format)
	$format.Dispose()
}

$background = [System.Drawing.Bitmap]::new((Join-Path $assets 'main-menu-background.png'))
$logo = [System.Drawing.Bitmap]::new((Join-Path $assets 'logo.png'))
$normalButton = [System.Drawing.Bitmap]::new((Join-Path $assets 'button-normal.png'))
$focusedButton = [System.Drawing.Bitmap]::new((Join-Path $assets 'button-focused.png'))
$canvas = [System.Drawing.Bitmap]::new($background.Width, $background.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)

try {
	$graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
	$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
	$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

	$graphics.DrawImageUnscaled($background, 0, 0)

	$shadeBounds = [System.Drawing.Rectangle]::new(0, 0, 760, $canvas.Height)
	$shade = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
		$shadeBounds,
		[System.Drawing.Color]::FromArgb(232, 3, 8, 12),
		[System.Drawing.Color]::FromArgb(0, 3, 8, 12),
		[System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
	)
	$graphics.FillRectangle($shade, $shadeBounds)
	$shade.Dispose()

	$logoBounds = [System.Drawing.Rectangle]::new(66, 65, 585, 214)
	$graphics.DrawImage($logo, $logoBounds)

	$buttonX = 118
	$buttonY = 330
	$buttonWidth = 480
	$buttonHeight = 82
	$buttonGap = 80
	$labels = @('CONTINUE', 'PLAY', 'SETTINGS', 'ACCESSIBILITY', 'CREDITS', 'QUIT')
	$textFont = [System.Drawing.Font]::new('Georgia', 24, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
	$textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(244, 224, 215, 199))
	$focusedBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 239, 221))
	$shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(190, 0, 0, 0))

	for ($index = 0; $index -lt $labels.Count; $index++) {
		$y = $buttonY + ($index * $buttonGap)
		$bounds = [System.Drawing.Rectangle]::new($buttonX, $y, $buttonWidth, $buttonHeight)
		$button = if ($labels[$index] -eq 'PLAY') { $focusedButton } else { $normalButton }
		$graphics.DrawImage($button, $bounds)

		$textBounds = [System.Drawing.RectangleF]::new($buttonX, $y - 1, $buttonWidth, $buttonHeight)
		$shadowBounds = [System.Drawing.RectangleF]::new($buttonX + 2, $y + 2, $buttonWidth, $buttonHeight)
		Draw-CenteredText -Graphics $graphics -Text $labels[$index] -Font $textFont -Brush $shadowBrush -Bounds $shadowBounds
		$brush = if ($labels[$index] -eq 'PLAY') { $focusedBrush } else { $textBrush }
		Draw-CenteredText -Graphics $graphics -Text $labels[$index] -Font $textFont -Brush $brush -Bounds $textBounds
	}

	$textFont.Dispose()
	$textBrush.Dispose()
	$focusedBrush.Dispose()
	$shadowBrush.Dispose()

	$footerFont = [System.Drawing.Font]::new('Georgia', 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
	$footerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(175, 203, 198, 190))
	$footerBounds = [System.Drawing.RectangleF]::new(28, $canvas.Height - 38, 630, 24)
	Draw-CenteredText -Graphics $graphics -Text 'VERSION 0.1  |  DEVELOPMENT BUILD' -Font $footerFont -Brush $footerBrush -Bounds $footerBounds
	$footerFont.Dispose()
	$footerBrush.Dispose()

	$canvas.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
	$graphics.Dispose()
	$canvas.Dispose()
	$background.Dispose()
	$logo.Dispose()
	$normalButton.Dispose()
	$focusedButton.Dispose()
}

Write-Output $outputPath
