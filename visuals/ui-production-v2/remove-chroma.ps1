[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$InputPath,

	[Parameter(Mandatory = $true)]
	[string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$InputPath = (Resolve-Path -LiteralPath $InputPath).Path
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$OutputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
	throw "Output directory does not exist: $OutputDirectory"
}
if ($InputPath -eq $OutputPath) {
	throw 'InputPath and OutputPath must be different files.'
}

Add-Type -AssemblyName System.Drawing

if (-not ("AethelnChromaRemoval" -as [type])) {
	Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class AethelnChromaRemoval
{
	public static void Convert(string inputPath, string outputPath)
	{
		using (var source = new Bitmap(inputPath))
		using (var bitmap = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb))
		{
			using (var graphics = Graphics.FromImage(bitmap))
			{
				graphics.DrawImageUnscaled(source, 0, 0);
			}

			var rectangle = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
			var data = bitmap.LockBits(rectangle, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
			var bytes = new byte[Math.Abs(data.Stride) * data.Height];
			Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);

			var left = bitmap.Width;
			var top = bitmap.Height;
			var right = -1;
			var bottom = -1;

			for (var y = 0; y < bitmap.Height; y++)
			{
				for (var x = 0; x < bitmap.Width; x++)
				{
					var index = (y * data.Stride) + (x * 4);
					var blue = bytes[index];
					var green = bytes[index + 1];
					var red = bytes[index + 2];
					var nonGreenMaximum = Math.Max(red, blue);
					var greenDominance = green - nonGreenMaximum;

					byte alpha;
					if (green >= 80 && greenDominance >= 80)
					{
						alpha = 0;
					}
					else if (green < 50 || greenDominance <= 15)
					{
						alpha = 255;
					}
					else
					{
						var t = (80.0 - greenDominance) / 65.0;
						t = Math.Max(0.0, Math.Min(1.0, t));
						t = t * t * (3.0 - (2.0 * t));
						alpha = (byte)Math.Round(255.0 * t);
					}

					if (alpha < 255 && green > nonGreenMaximum)
					{
						green = (byte)Math.Min(255, nonGreenMaximum + 4);
					}

					bytes[index + 1] = green;
					bytes[index + 3] = alpha;

					if (alpha > 8)
					{
						left = Math.Min(left, x);
						right = Math.Max(right, x);
						top = Math.Min(top, y);
						bottom = Math.Max(bottom, y);
					}
				}
			}

			Marshal.Copy(bytes, 0, data.Scan0, bytes.Length);
			bitmap.UnlockBits(data);

			if (right < left || bottom < top)
			{
				throw new InvalidOperationException("No non-transparent subject pixels were found.");
			}

			const int padding = 8;
			left = Math.Max(0, left - padding);
			top = Math.Max(0, top - padding);
			right = Math.Min(bitmap.Width - 1, right + padding);
			bottom = Math.Min(bitmap.Height - 1, bottom + padding);
			var crop = new Rectangle(left, top, right - left + 1, bottom - top + 1);

			using (var output = new Bitmap(crop.Width, crop.Height, PixelFormat.Format32bppArgb))
			using (var graphics = Graphics.FromImage(output))
			{
				graphics.CompositingMode = CompositingMode.SourceCopy;
				graphics.DrawImage(bitmap, new Rectangle(0, 0, crop.Width, crop.Height), crop, GraphicsUnit.Pixel);
				output.Save(outputPath, ImageFormat.Png);
			}
		}
	}
}
"@
}

[AethelnChromaRemoval]::Convert($InputPath, $OutputPath)
