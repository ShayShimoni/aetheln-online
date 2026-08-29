[CmdletBinding()]
param(
	[string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path -LiteralPath $Root).Path

Add-Type -AssemblyName System.Drawing

if (-not ("AethelnScreenPreviews" -as [type])) {
	Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;

public static class AethelnScreenPreviews
{
	private const int W = 1672;
	private const int H = 941;

	private static Graphics Begin(Bitmap canvas, Bitmap background, int shade)
	{
		var g = Graphics.FromImage(canvas);
		g.CompositingQuality = CompositingQuality.HighQuality;
		g.InterpolationMode = InterpolationMode.HighQualityBicubic;
		g.PixelOffsetMode = PixelOffsetMode.HighQuality;
		g.SmoothingMode = SmoothingMode.HighQuality;
		g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
		g.DrawImage(background, new Rectangle(0, 0, W, H));
		if (shade > 0)
		{
			using (var brush = new SolidBrush(Color.FromArgb(shade, 2, 6, 10)))
				g.FillRectangle(brush, 0, 0, W, H);
		}
		return g;
	}

	private static void Text(Graphics g, string value, float size, RectangleF bounds, Color color, bool center = false)
	{
		using (var font = new Font("Georgia", size, FontStyle.Regular, GraphicsUnit.Pixel))
		using (var brush = new SolidBrush(color))
		using (var format = new StringFormat())
		{
			format.Alignment = center ? StringAlignment.Center : StringAlignment.Near;
			format.LineAlignment = StringAlignment.Center;
			format.FormatFlags = StringFormatFlags.NoWrap;
			g.DrawString(value, font, brush, bounds, format);
		}
	}

	private static void Button(Graphics g, Bitmap texture, string label, int x, int y, int width, int height)
	{
		g.DrawImage(texture, new Rectangle(x, y, width, height));
		Text(g, label, 20, new RectangleF(x, y - 1, width, height), Color.FromArgb(245, 231, 216), true);
	}

	private static void Line(Graphics g, int x1, int y, int x2)
	{
		using (var pen = new Pen(Color.FromArgb(95, 181, 171, 157), 1))
			g.DrawLine(pen, x1, y, x2, y);
	}

	private static void Save(Bitmap image, string root, string name)
	{
		image.Save(Path.Combine(root, "previews", name), ImageFormat.Png);
	}

	private static void BuildSettings(string root, string page, bool accessibility)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var panel = new Bitmap(Path.Combine(a, "panel-large.png")))
		using (var normal = new Bitmap(Path.Combine(a, "button-normal.png")))
		using (var focus = new Bitmap(Path.Combine(a, "button-focused.png")))
		using (var slider = new Bitmap(Path.Combine(a, "slider-cyan-65.png")))
		using (var toggleOn = new Bitmap(Path.Combine(a, "toggle-on.png")))
		using (var toggleOff = new Bitmap(Path.Combine(a, "toggle-off.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 150))
		{
			g.DrawImage(panel, new Rectangle(255, 82, 1162, 778));
			Text(g, page, 42, new RectangleF(450, 106, 772, 60), Color.FromArgb(238, 224, 207), true);

			string[] tabs = { "DISPLAY", "AUDIO", "CONTROLS", "ACCESSIBILITY" };
			for (int i = 0; i < tabs.Length; i++)
				Button(g, tabs[i] == page ? focus : normal, tabs[i], 326, 208 + (i * 70), 270, 58);

			int left = 660;
			int top = 226;
			if (!accessibility)
			{
				string[] labels = { "DISPLAY MODE", "RESOLUTION", "MASTER VOLUME", "MUSIC VOLUME", "V-SYNC", "SUBTITLES" };
				for (int i = 0; i < labels.Length; i++)
				{
					int y = top + (i * 82);
					Text(g, labels[i], 19, new RectangleF(left, y, 270, 54), Color.FromArgb(224, 216, 204));
					Line(g, left, y + 62, 1308);
				}
				Button(g, normal, "BORDERLESS", 1030, top + 2, 260, 52);
				Button(g, normal, "2560 x 1440", 1030, top + 84, 260, 52);
				g.DrawImage(slider, new Rectangle(1000, top + 178, 300, 54));
				g.DrawImage(slider, new Rectangle(1000, top + 260, 300, 54));
				g.DrawImage(toggleOn, new Rectangle(1175, top + 337, 112, 47));
				g.DrawImage(toggleOff, new Rectangle(1175, top + 419, 112, 47));
			}
			else
			{
				string[] labels = { "SUBTITLES", "TEXT SCALE", "HIGH CONTRAST FOCUS", "CAMERA SHAKE", "HOLD TO SPRINT", "COLOR FILTER" };
				for (int i = 0; i < labels.Length; i++)
				{
					int y = top + (i * 82);
					Text(g, labels[i], 19, new RectangleF(left, y, 340, 54), Color.FromArgb(224, 216, 204));
					Line(g, left, y + 62, 1308);
				}
				g.DrawImage(toggleOn, new Rectangle(1175, top + 7, 112, 47));
				g.DrawImage(slider, new Rectangle(1000, top + 96, 300, 54));
				g.DrawImage(toggleOn, new Rectangle(1175, top + 171, 112, 47));
				g.DrawImage(slider, new Rectangle(1000, top + 260, 300, 54));
				g.DrawImage(toggleOff, new Rectangle(1175, top + 335, 112, 47));
				Button(g, normal, "NONE", 1030, top + 412, 260, 52);
			}

			Button(g, focus, "APPLY", 852, 762, 220, 58);
			Button(g, normal, "BACK", 1090, 762, 220, 58);
			Save(canvas, root, accessibility ? "accessibility-v2-preview.png" : "settings-v2-preview.png");
		}
	}

	private static void BuildCharacterSelection(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "character-selection-stage.png")))
		using (var character = new Bitmap(Path.Combine(a, "kell-female-selection.png")))
		using (var lineup = new Bitmap(Path.Combine(a, "playable-peoples-reference.png")))
		using (var card = new Bitmap(Path.Combine(a, "selection-card-frame.png")))
		using (var panel = new Bitmap(Path.Combine(a, "panel-large.png")))
		using (var normal = new Bitmap(Path.Combine(a, "button-normal.png")))
		using (var focus = new Bitmap(Path.Combine(a, "button-focused.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 18))
		{
			Text(g, "SELECT CHARACTER", 42, new RectangleF(48, 24, 620, 70), Color.FromArgb(231, 221, 207));
			Line(g, 48, 98, 560);

			g.DrawImage(character, new Rectangle(706, 92, 224, 738));
			g.DrawImage(panel, new Rectangle(1200, 130, 425, 560));
			Text(g, "KELL", 48, new RectangleF(1255, 220, 315, 70), Color.FromArgb(235, 223, 207), true);
			Line(g, 1260, 315, 1560);
			Text(g, "LEVEL 1", 21, new RectangleF(1280, 340, 270, 50), Color.FromArgb(220, 210, 197));
			Text(g, "FACTION UNASSIGNED", 18, new RectangleF(1280, 405, 285, 50), Color.FromArgb(220, 210, 197));
			Text(g, "APPEARANCE", 18, new RectangleF(1280, 500, 285, 50), Color.FromArgb(182, 175, 166));
			Text(g, "Combat rules remain identical", 15, new RectangleF(1280, 540, 285, 40), Color.FromArgb(145, 189, 190));

			Rectangle[] sources = {
				new Rectangle(305, 45, 255, 650),
				new Rectangle(848, 45, 250, 650),
				new Rectangle(1368, 45, 245, 650)
			};
			for (int i = 0; i < 3; i++)
			{
				int y = 145 + (i * 205);
				g.DrawImage(lineup, new Rectangle(64, y + 18, 126, 164), sources[i], GraphicsUnit.Pixel);
				g.DrawImage(card, new Rectangle(42, y, 170, 190));
			}
			Button(g, normal, "BACK", 42, 845, 250, 58);
			Button(g, normal, "DELETE", 330, 845, 250, 58);
			Button(g, focus, "ENTER WORLD", 620, 835, 460, 68);
			Button(g, normal, "CREATE CHARACTER", 1120, 845, 460, 58);
			Save(canvas, root, "character-selection-v2-preview.png");
		}
	}

	private static void BuildHud(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var status = new Bitmap(Path.Combine(a, "hud-status-frame.png")))
		using (var slot = new Bitmap(Path.Combine(a, "slot-frame.png")))
		using (var attack = new Bitmap(Path.Combine(a, "icon-basic-attack.png")))
		using (var dodge = new Bitmap(Path.Combine(a, "icon-dodge.png")))
		using (var block = new Bitmap(Path.Combine(a, "icon-block.png")))
		using (var consumable = new Bitmap(Path.Combine(a, "icon-health-consumable.png")))
		using (var buff = new Bitmap(Path.Combine(a, "icon-buff.png")))
		using (var debuff = new Bitmap(Path.Combine(a, "icon-debuff.png")))
		using (var reticle = new Bitmap(Path.Combine(a, "reticle-free-aim.png")))
		using (var objective = new Bitmap(Path.Combine(a, "marker-objective.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 18))
		{
			g.DrawImage(status, new Rectangle(38, 36, 440, 70));
			using (var hp = new SolidBrush(Color.FromArgb(210, 151, 53, 43)))
				g.FillRectangle(hp, 83, 70, 325, 13);
			Text(g, "742 / 1000", 15, new RectangleF(90, 48, 300, 34), Color.FromArgb(245, 229, 214), true);
			g.DrawImage(status, new Rectangle(38, 105, 360, 57));
			using (var mp = new SolidBrush(Color.FromArgb(210, 45, 159, 166)))
				g.FillRectangle(mp, 76, 133, 232, 10);

			int start = 540;
			for (int i = 0; i < 7; i++)
			{
				int x = start + (i * 88);
				g.DrawImage(slot, new Rectangle(x, 820, 78, 88));
				Text(g, (i + 1).ToString(), 14, new RectangleF(x + 20, 874, 38, 22), Color.FromArgb(235, 226, 213), true);
			}
			Bitmap[] actions = { attack, dodge, block, consumable };
			for (int i = 0; i < actions.Length; i++)
			{
				int x = start + (i * 88);
				g.DrawImage(actions[i], new Rectangle(x + 14, 831, 50, 50));
			}
			g.DrawImage(buff, new Rectangle(48, 180, 42, 48));
			g.DrawImage(debuff, new Rectangle(98, 180, 42, 48));
			g.DrawImage(reticle, new Rectangle(806, 438, 60, 60));
			g.DrawImage(objective, new Rectangle(1248, 244, 36, 76));
			Text(g, "EMBER", 15, new RectangleF(1450, 45, 150, 30), Color.FromArgb(225, 214, 200), true);
			g.DrawImage(status, new Rectangle(1420, 76, 205, 42));
			Save(canvas, root, "hud-v2-preview.png");
		}
	}

	private static void BuildInventory(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var panel = new Bitmap(Path.Combine(a, "panel-large.png")))
		using (var slot = new Bitmap(Path.Combine(a, "slot-frame.png")))
		using (var normal = new Bitmap(Path.Combine(a, "button-normal.png")))
		using (var weapon = new Bitmap(Path.Combine(a, "icon-basic-attack.png")))
		using (var armor = new Bitmap(Path.Combine(a, "icon-block.png")))
		using (var consumable = new Bitmap(Path.Combine(a, "icon-health-consumable.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 160))
		{
			g.DrawImage(panel, new Rectangle(120, 65, 1432, 810));
			Text(g, "INVENTORY", 42, new RectangleF(510, 95, 650, 60), Color.FromArgb(235, 223, 207), true);
			Text(g, "EQUIPPED", 20, new RectangleF(220, 175, 300, 40), Color.FromArgb(200, 193, 181));
			Text(g, "PACK  18 / 40", 20, new RectangleF(690, 175, 610, 40), Color.FromArgb(200, 193, 181));

			for (int i = 0; i < 6; i++)
			{
				int x = 245 + ((i % 2) * 150);
				int y = 245 + ((i / 2) * 175);
				g.DrawImage(slot, new Rectangle(x, y, 130, 145));
			}
			for (int i = 0; i < 24; i++)
			{
				int x = 680 + ((i % 6) * 112);
				int y = 230 + ((i / 6) * 130);
				g.DrawImage(slot, new Rectangle(x, y, 98, 110));
			}
			g.DrawImage(weapon, new Rectangle(267, 262, 86, 86));
			g.DrawImage(armor, new Rectangle(417, 262, 86, 86));
			g.DrawImage(consumable, new Rectangle(701, 247, 58, 78));
			g.DrawImage(consumable, new Rectangle(813, 247, 58, 78));
			Button(g, normal, "SORT", 1050, 755, 210, 54);
			Button(g, normal, "CLOSE", 1280, 755, 210, 54);
			Save(canvas, root, "inventory-v2-preview.png");
		}
	}

	private static void BuildLoading(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var logo = new Bitmap(Path.Combine(a, "logo.png")))
		using (var loader = new Bitmap(Path.Combine(a, "loading-indicator.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 120))
		{
			g.DrawImage(logo, new Rectangle(532, 145, 608, 222));
			g.DrawImage(loader, new Rectangle(722, 430, 228, 228));
			Text(g, "LOADING", 25, new RectangleF(650, 674, 372, 50), Color.FromArgb(236, 223, 208), true);
			Line(g, 460, 750, 1212);
			Text(g, "Aim, timing, position, blocking and dodging remain decisive.", 17, new RectangleF(400, 768, 872, 45), Color.FromArgb(192, 192, 188), true);
			Save(canvas, root, "loading-v2-preview.png");
		}
	}

	private static void BuildDialog(string root)
	{
		var a = Path.Combine(root, "assets");
		using (var bg = new Bitmap(Path.Combine(a, "main-menu-background.png")))
		using (var panel = new Bitmap(Path.Combine(a, "panel-large.png")))
		using (var normal = new Bitmap(Path.Combine(a, "button-normal.png")))
		using (var focus = new Bitmap(Path.Combine(a, "button-focused.png")))
		using (var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb))
		using (var g = Begin(canvas, bg, 185))
		{
			g.DrawImage(panel, new Rectangle(450, 218, 772, 505));
			Text(g, "LEAVE GAME?", 38, new RectangleF(590, 270, 492, 58), Color.FromArgb(237, 223, 207), true);
			Line(g, 560, 350, 1112);
			Text(g, "Your current session will end.", 21, new RectangleF(560, 372, 552, 52), Color.FromArgb(208, 201, 191), true);
			Button(g, focus, "LEAVE", 575, 575, 250, 62);
			Button(g, normal, "CANCEL", 845, 575, 250, 62);

			g.DrawImage(panel, new Rectangle(1170, 610, 420, 245));
			Text(g, "FOCUS", 20, new RectangleF(1215, 650, 320, 36), Color.FromArgb(235, 221, 205));
			Text(g, "Orange outlines show keyboard", 15, new RectangleF(1215, 695, 320, 30), Color.FromArgb(190, 187, 180));
			Text(g, "and controller focus.", 15, new RectangleF(1215, 725, 320, 30), Color.FromArgb(190, 187, 180));
			Save(canvas, root, "dialog-tooltip-v2-preview.png");
		}
	}

	public static void BuildAll(string root)
	{
		Directory.CreateDirectory(Path.Combine(root, "previews"));
		BuildSettings(root, "DISPLAY", false);
		BuildSettings(root, "ACCESSIBILITY", true);
		BuildCharacterSelection(root);
		BuildHud(root);
		BuildInventory(root);
		BuildLoading(root);
		BuildDialog(root);
	}
}
"@
}

[AethelnScreenPreviews]::BuildAll($Root)
Get-ChildItem -LiteralPath (Join-Path $Root 'previews') -Filter '*-v2-preview.png' |
	Sort-Object Name |
	Select-Object -ExpandProperty FullName
