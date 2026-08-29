[CmdletBinding()]
param(
	[string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path -LiteralPath $Root).Path
$PreviewDirectory = Join-Path $Root 'previews'
[System.IO.Directory]::CreateDirectory($PreviewDirectory) | Out-Null

Add-Type -AssemblyName System.Drawing

if (-not ("AethelnGameplayPreview" -as [type])) {
	Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;

public static class AethelnGameplayPreview
{
	private const int W = 1672;
	private const int H = 941;

	private static void Text(Graphics g, string value, float size, RectangleF bounds, Color color, bool center)
	{
		using (var font = new Font("Georgia", size, FontStyle.Regular, GraphicsUnit.Pixel))
		using (var brush = new SolidBrush(color))
		using (var format = new StringFormat())
		{
			format.Alignment = center ? StringAlignment.Center : StringAlignment.Near;
			format.LineAlignment = StringAlignment.Center;
			g.DrawString(value, font, brush, bounds, format);
		}
	}

	private static void DrawAsset(Graphics g, Bitmap slot, Bitmap asset, string label, int x, int y)
	{
		g.DrawImage(slot, new Rectangle(x, y, 154, 168));
		g.DrawImage(asset, new Rectangle(x + 31, y + 27, 92, 92));
		Text(g, label, 17, new RectangleF(x - 18, y + 174, 190, 32), Color.FromArgb(225, 216, 204), true);
	}

	public static void Build(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var panel = new Bitmap(Path.Combine(a, "panel-large.png")))
		using (var slot = new Bitmap(Path.Combine(a, "slot-frame.png")))
		using (var attack = new Bitmap(Path.Combine(a, "icon-basic-attack.png")))
		using (var dodge = new Bitmap(Path.Combine(a, "icon-dodge.png")))
		using (var block = new Bitmap(Path.Combine(a, "icon-block.png")))
		using (var health = new Bitmap(Path.Combine(a, "icon-health-consumable.png")))
		using (var buff = new Bitmap(Path.Combine(a, "icon-buff.png")))
		using (var debuff = new Bitmap(Path.Combine(a, "icon-debuff.png")))
		using (var reticle = new Bitmap(Path.Combine(a, "reticle-free-aim.png")))
		using (var interact = new Bitmap(Path.Combine(a, "marker-interact.png")))
		using (var objective = new Bitmap(Path.Combine(a, "marker-objective.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Graphics.FromImage(canvas))
		{
			g.CompositingQuality = CompositingQuality.HighQuality;
			g.InterpolationMode = InterpolationMode.HighQualityBicubic;
			g.SmoothingMode = SmoothingMode.HighQuality;
			g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
			g.DrawImage(bg, new Rectangle(0, 0, W, H));
			using (var shade = new SolidBrush(Color.FromArgb(176, 2, 6, 10)))
				g.FillRectangle(shade, 0, 0, W, H);
			g.DrawImage(panel, new Rectangle(72, 42, 1528, 850));
			Text(g, "GAMEPLAY ASSETS", 40, new RectangleF(130, 78, 1412, 58), Color.FromArgb(239, 226, 210), true);
			using (var pen = new Pen(Color.FromArgb(100, 181, 171, 157), 1))
				g.DrawLine(pen, 150, 150, 1522, 150);

			DrawAsset(g, slot, attack, "BASIC ATTACK", 150, 196);
			DrawAsset(g, slot, dodge, "DODGE", 342, 196);
			DrawAsset(g, slot, block, "BLOCK", 534, 196);
			DrawAsset(g, slot, health, "HEALTH", 726, 196);
			DrawAsset(g, slot, buff, "POSITIVE", 918, 196);
			DrawAsset(g, slot, debuff, "NEGATIVE", 1110, 196);

			Text(g, "FREE AIM", 20, new RectangleF(160, 485, 360, 36), Color.FromArgb(206, 198, 187), false);
			using (var field = new SolidBrush(Color.FromArgb(205, 8, 13, 17)))
				g.FillEllipse(field, 160, 536, 300, 300);
			using (var rim = new Pen(Color.FromArgb(120, 150, 168, 168), 2))
				g.DrawEllipse(rim, 160, 536, 300, 300);
			g.DrawImage(reticle, new Rectangle(265, 641, 90, 90));
			Text(g, "Thin neutral reticle - no target lock", 16, new RectangleF(480, 645, 380, 60), Color.FromArgb(176, 190, 190, 185), false);

			Text(g, "WORLD MARKERS", 20, new RectangleF(885, 485, 500, 36), Color.FromArgb(206, 198, 187), false);
			g.DrawImage(interact, new Rectangle(925, 565, 105, 184));
			g.DrawImage(objective, new Rectangle(1192, 552, 88, 184));
			Text(g, "INTERACT", 17, new RectangleF(874, 770, 210, 34), Color.FromArgb(225, 216, 204), true);
			Text(g, "OBJECTIVE", 17, new RectangleF(1130, 770, 210, 34), Color.FromArgb(225, 216, 204), true);
			Text(g, "Starter semantics only - final class abilities, item tiers and faction symbols remain TBD", 15,
				new RectangleF(250, 810, 1172, 28), Color.FromArgb(154, 177, 177, 172), true);

			canvas.Save(Path.Combine(root, "previews", "gameplay-icons-v2-preview.png"), ImageFormat.Png);
		}
	}
}
"@
}

[AethelnGameplayPreview]::Build($Root)
Join-Path $Root 'previews\gameplay-icons-v2-preview.png'
