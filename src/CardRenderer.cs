using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;

namespace PearNowPlaying
{
    internal enum CardKind { NowPlaying, Paused, Resumed, Info }

    /// <summary>
    /// Draws the overlay pieces into 32bpp ARGB bitmaps (for per-pixel-alpha layered windows),
    /// using the carol-web look: surface card, 1px soft border, 16px radius, Pretendard, coral accent.
    /// </summary>
    internal static class CardRenderer
    {
        // ---- now playing card ------------------------------------------------------

        /// <summary>Single still frame of the card (long titles end in "…" instead of scrolling).</summary>
        public static Bitmap RenderCard(SongInfo song, CardKind kind, string infoText, Image art, bool showArt,
                                        double scale, double opacity, int fixedWidth = 0)
        {
            using (var frame = BuildCard(song, kind, infoText, art, showArt, scale, opacity, fixedWidth, false))
                return frame.Compose(0);
        }

        /// <param name="fixedWidth">total card width in pixels (shared with the lyrics panel); 0 = fit the text</param>
        /// <param name="marquee">true: a title that doesn't fit is left out of the base image so it can scroll</param>
        public static CardFrame BuildCard(SongInfo song, CardKind kind, string infoText, Image art, bool showArt,
                                          double scale, double opacity, int fixedWidth, bool marquee)
        {
            float s = (float)scale;
            int pad = R(16 * s);
            int artSize = showArt && kind != CardKind.Info ? R(60 * s) : 0;
            int gap = artSize > 0 ? R(14 * s) : 0;
            int minText = kind == CardKind.Info ? R(140 * s) : R(220 * s), maxText = R(380 * s);

            string title = kind == CardKind.Info ? infoText : (song != null && song.Title.Length > 0 ? song.Title : "알 수 없는 곡");
            string sub = kind == CardKind.Info ? "" : Subtitle(song);
            string label = LabelText(kind);
            string time = kind == CardKind.Info || song == null ? "" : TimeText(song);
            bool hasBar = song != null && kind != CardKind.Info && song.Duration > 0;

            var labelFont = Fonts.Get(Weight.Medium, 12f * s, label);
            var timeFont = Fonts.Get(Weight.Regular, 12f * s, time);
            var titleFont = Fonts.Get(Weight.Medium, 17f * s, title);
            var subFont = Fonts.Get(Weight.Regular, 13f * s, sub);
            float iconSize = 8 * s, barH = Math.Max(2f, 3 * s);

            int textW;
            float headerH, titleH, subH, titleW;
            using (var probe = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(probe))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                float w = Math.Max(g.MeasureString(title, titleFont).Width, sub.Length > 0 ? g.MeasureString(sub, subFont).Width : 0);
                float header = iconSize + 6 * s + g.MeasureString(label, labelFont).Width
                               + (time.Length > 0 ? g.MeasureString(time, timeFont).Width + 16 * s : 0);
                textW = fixedWidth > 0
                    ? Math.Max(R(80 * s), fixedWidth - pad * 2 - artSize - gap)
                    : Clamp((int)Math.Ceiling(Math.Max(w, header)), minText, maxText);
                titleW = g.MeasureString(title, titleFont).Width;
                headerH = LineHeight(labelFont, g);
                titleH = LineHeight(titleFont, g);
                subH = sub.Length > 0 ? LineHeight(subFont, g) : 0;
            }
            float textBlockH = headerH + 4 * s + titleH + (sub.Length > 0 ? 1 * s + subH : 0) + (hasBar ? 9 * s + barH : 0);
            int contentH = (int)Math.Ceiling(Math.Max(artSize, textBlockH));
            int width = pad + artSize + gap + textW + pad;
            int height = pad + contentH + pad;

            bool scrolls = marquee && titleW > textW + 0.5f;
            var frame = new CardFrame();
            var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            frame.Base = bmp;
            using (var g = Graphics.FromImage(bmp))
            {
                Prepare(g);
                DrawSurface(g, width, height, s, opacity);

                if (artSize > 0)
                {
                    var artRect = new Rectangle(pad, pad + (contentH - artSize) / 2, artSize, artSize);
                    DrawArt(g, art, artRect, 10 * s);
                }

                float x = pad + artSize + gap;
                float y = pad + (contentH - textBlockH) / 2f;

                var labelColor = kind == CardKind.Paused ? Theme.Muted : Theme.AccentSoft;
                DrawKindIcon(g, kind, new RectangleF(x, y + (headerH - iconSize) / 2f, iconSize, iconSize),
                             kind == CardKind.Paused ? Theme.Muted : Theme.Accent);
                DrawLine(g, label, labelFont, labelColor, x + iconSize + 6 * s, y, textW, headerH);
                if (time.Length > 0)
                {
                    using (var tb = new SolidBrush(Theme.Dim))
                    using (var rf = new StringFormat(StringFormatFlags.NoWrap) { Alignment = StringAlignment.Far })
                        g.DrawString(time, timeFont, tb, new RectangleF(x, y, textW, headerH + 2), rf);
                }
                y += headerH + 4 * s;

                if (scrolls)
                {
                    frame.Title = title;
                    frame.TitleFont = titleFont;
                    frame.TitleColor = Theme.Ink;
                    frame.TitleRect = new RectangleF(x, y, textW, titleH);
                    frame.TitleWidth = titleW;
                    frame.Gap = 40 * s;
                    frame.FadeWidth = 18 * s;
                }
                else DrawLine(g, Fit(g, title, titleFont, textW), titleFont, Theme.Ink, x, y, textW, titleH);
                y += titleH;
                if (sub.Length > 0)
                {
                    y += 1 * s;
                    DrawLine(g, Fit(g, sub, subFont, textW), subFont, Theme.Muted, x, y, textW, subH);
                    y += subH;
                }

                if (hasBar)
                {
                    float barY = y + 9 * s;
                    float frac = (float)Math.Max(0, Math.Min(1, song.Elapsed / song.Duration));
                    using (var track = Rounded(new RectangleF(x, barY, textW, barH), barH / 2))
                    using (var trackBrush = new SolidBrush(Theme.Surface2))
                        g.FillPath(trackBrush, track);
                    if (frac > 0.002f)
                        using (var fill = Rounded(new RectangleF(x, barY, Math.Max(barH, textW * frac), barH), barH / 2))
                        using (var fillBrush = new SolidBrush(kind == CardKind.Paused ? Theme.Dim : Theme.Accent))
                            g.FillPath(fillBrush, fill);
                }
            }
            return frame;
        }

        // ---- shared pieces ------------------------------------------------------------

        static void Prepare(Graphics g)
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
        }

        // bg-surface + border-border-soft + rounded-2xl
        static void DrawSurface(Graphics g, int width, int height, float s, double opacity)
        {
            int a = Clamp((int)Math.Round(255 * opacity), 0, 255);
            using (var path = Rounded(new RectangleF(0.5f, 0.5f, width - 1, height - 1), 16 * s))
            {
                using (var bg = new SolidBrush(Theme.WithAlpha(Theme.Surface, a))) g.FillPath(bg, path);
                using (var border = new Pen(Theme.WithAlpha(Theme.BorderSoft, Math.Min(255, a + 20)), 1f)) g.DrawPath(border, path);
            }
        }

        // rounded-lg image with the 0 0 0 1px #33333a ring
        static void DrawArt(Graphics g, Image art, Rectangle r, float radius)
        {
            using (var clip = Rounded(r, radius))
            {
                if (art != null)
                {
                    var state = g.Save();
                    g.SetClip(clip);
                    float side = Math.Min(art.Width, art.Height);
                    g.DrawImage(art, r, new RectangleF((art.Width - side) / 2f, (art.Height - side) / 2f, side, side), GraphicsUnit.Pixel);
                    g.Restore(state);
                }
                else
                {
                    using (var b = new SolidBrush(Theme.Surface2)) g.FillPath(b, clip);
                    var note = Fonts.Get(Weight.Medium, r.Height * 0.42f, "♪");
                    using (var nb = new SolidBrush(Theme.Dim))
                    using (var c = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                        g.DrawString("♪", note, nb, r, c);
                }
                using (var ring = new Pen(Theme.BorderSoft, 1f)) g.DrawPath(ring, clip);
            }
        }

        static void DrawLine(Graphics g, string text, Font font, Color color, float x, float y, float w, float h)
        {
            using (var b = new SolidBrush(color))
            using (var sf = new StringFormat(StringFormatFlags.NoWrap) { Trimming = StringTrimming.EllipsisCharacter })
                g.DrawString(text, font, b, new RectangleF(x, y, w + 4, h + 2), sf);
        }

        /// <summary>Line spacing in pixels from the font's own metrics (same value as Font.GetHeight for pixel-sized fonts).</summary>
        internal static float LineHeight(Font f, Graphics g)
        {
            try
            {
                var fam = f.FontFamily;
                int em = fam.GetEmHeight(f.Style);
                if (em > 0) return f.Size * fam.GetLineSpacing(f.Style) / em;
            }
            catch (ArgumentException) { }
            try { return f.GetHeight(g); }
            catch (ArgumentException) { return g.MeasureString("Ag가", f).Height; }
        }

        /// <summary>
        /// Word-wraps into at most maxLines lines; the last line gets "…" if text is left over.
        /// Breaks at spaces when possible, otherwise between characters (CJK lines often have no spaces).
        /// </summary>
        internal static List<string> Wrap(Graphics g, string text, Font font, float width, int maxLines)
        {
            var lines = new List<string>();
            var rest = text.Trim();
            while (rest.Length > 0 && lines.Count < maxLines)
            {
                if (lines.Count == maxLines - 1 || g.MeasureString(rest, font).Width <= width)
                {
                    lines.Add(Fit(g, rest, font, width));
                    break;
                }
                int lo = 1, hi = rest.Length;   // longest prefix that fits
                while (lo < hi)
                {
                    int mid = (lo + hi + 1) / 2;
                    if (g.MeasureString(rest.Substring(0, mid), font).Width <= width) lo = mid; else hi = mid - 1;
                }
                int cut = lo;
                if (cut < rest.Length && rest[cut] != ' ')
                {
                    int sp = rest.LastIndexOf(' ', cut - 1, cut);
                    if (sp > 0) cut = sp;
                }
                lines.Add(rest.Substring(0, cut).TrimEnd());
                rest = rest.Substring(cut).TrimStart();
            }
            if (lines.Count == 0) lines.Add("");
            return lines;
        }

        /// <summary>Shortens text with "…" so it fits (StringTrimming is not reliable everywhere).</summary>
        internal static string Fit(Graphics g, string text, Font font, float maxW)
        {
            if (string.IsNullOrEmpty(text) || g.MeasureString(text, font).Width <= maxW) return text;
            int lo = 0, hi = text.Length;
            while (lo < hi)
            {
                int mid = (lo + hi + 1) / 2;
                if (g.MeasureString(text.Substring(0, mid).TrimEnd() + "…", font).Width <= maxW) lo = mid; else hi = mid - 1;
            }
            return text.Substring(0, lo).TrimEnd() + "…";
        }

        static void DrawKindIcon(Graphics g, CardKind kind, RectangleF r, Color color)
        {
            using (var b = new SolidBrush(color))
            {
                if (kind == CardKind.Paused)
                {
                    float w = r.Width * 0.34f;
                    g.FillRectangle(b, r.X, r.Y, w, r.Height);
                    g.FillRectangle(b, r.Right - w, r.Y, w, r.Height);
                }
                else if (kind == CardKind.Info) g.FillEllipse(b, r);
                else g.FillPolygon(b, new[] { new PointF(r.X, r.Y), new PointF(r.Right, r.Y + r.Height / 2), new PointF(r.X, r.Bottom) });
            }
        }

        static string LabelText(CardKind kind)
        {
            switch (kind)
            {
                case CardKind.Paused: return "일시정지됨";
                case CardKind.Info: return "Now Playing Widget";
                default: return "재생중";   // also when playback resumes
            }
        }

        static string Subtitle(SongInfo song)
        {
            if (song == null) return "";
            var artist = song.Artist ?? "";
            var album = song.Album ?? "";
            if (artist.Length > 0 && album.Length > 0 && album != song.Title) return artist + " · " + album;
            return artist.Length > 0 ? artist : album;
        }

        static string TimeText(SongInfo song)
        {
            if (song.Duration <= 0) return "";
            return Fmt(song.Elapsed) + " / " + Fmt(song.Duration);
        }

        static string Fmt(double seconds)
        {
            if (seconds < 0) seconds = 0;
            var t = TimeSpan.FromSeconds(Math.Floor(seconds));
            return t.TotalHours >= 1
                ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", (int)t.TotalHours, t.Minutes, t.Seconds)
                : string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}", t.Minutes, t.Seconds);
        }

        public static GraphicsPath Rounded(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 0.5f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static int R(float v) { return (int)Math.Round(v); }
        static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

        /// <summary>Tray icon in carol's primary-button colors: coral square, accent-ink note.</summary>
        public static Icon MakeTrayIcon(int size)
        {
            using (var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (var p = Rounded(new RectangleF(0.5f, 0.5f, size - 1, size - 1), size * 0.24f))
                    using (var b = new SolidBrush(Theme.Accent)) g.FillPath(b, p);
                    using (var w = new SolidBrush(Theme.AccentInk))
                    {
                        float u = size / 16f;
                        g.FillEllipse(w, 3.2f * u, 9.4f * u, 4.6f * u, 3.6f * u);
                        g.FillRectangle(w, 6.6f * u, 3.2f * u, 1.3f * u, 8f * u);
                        g.FillPolygon(w, new[] { new PointF(6.6f * u, 3.2f * u), new PointF(11.8f * u, 4.6f * u), new PointF(11.8f * u, 6.6f * u), new PointF(6.6f * u, 5.4f * u) });
                    }
                }
                IntPtr h = bmp.GetHicon();
                var icon = (Icon)Icon.FromHandle(h).Clone();
                Native.DestroyIcon(h);
                return icon;
            }
        }
    }

    /// <summary>
    /// A card whose static parts are drawn once (art scaling is the expensive bit) and whose overflowing
    /// title is drawn per frame at a horizontal offset, looping with a gap and fading at the cut edges.
    /// </summary>
    internal sealed class CardFrame : IDisposable
    {
        public Bitmap Base;
        public string Title;
        public Font TitleFont;
        public Color TitleColor;
        public RectangleF TitleRect;
        public float TitleWidth, Gap, FadeWidth;

        public bool Scrolls { get { return Title != null; } }
        public Size Size { get { return Base.Size; } }

        /// <summary>Distance after which the scrolling title looks exactly like the start again.</summary>
        public float Cycle { get { return TitleWidth + Gap; } }

        public Bitmap Compose(float offset)
        {
            var bmp = Base.Clone(new Rectangle(0, 0, Base.Width, Base.Height), PixelFormat.Format32bppArgb);
            if (!Scrolls) return bmp;

            int lw = Math.Max(1, (int)Math.Ceiling(TitleRect.Width));
            int lh = Math.Max(1, (int)Math.Ceiling(TitleRect.Height) + 2);
            using (var layer = new Bitmap(lw, lh, PixelFormat.Format32bppArgb))
            {
                float o = Cycle > 0 ? offset % Cycle : 0;
                using (var g = Graphics.FromImage(layer))
                using (var brush = new SolidBrush(TitleColor))
                using (var sf = new StringFormat(StringFormatFlags.NoWrap))
                {
                    g.Clear(Color.Transparent);
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    g.DrawString(Title, TitleFont, brush, -o, 0, sf);
                    if (TitleWidth - o < lw) g.DrawString(Title, TitleFont, brush, Cycle - o, 0, sf);
                }
                // fade the right edge always (text runs past it); the left edge only while text slides under it
                FadeEdges(layer, o > 0.5f ? FadeWidth : 0, FadeWidth);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
                    g.DrawImageUnscaled(layer, (int)Math.Round(TitleRect.X), (int)Math.Round(TitleRect.Y));
                }
            }
            return bmp;
        }

        /// <summary>Multiplies the alpha channel by a ramp on the left/right edges.</summary>
        static void FadeEdges(Bitmap layer, float left, float right)
        {
            var rect = new Rectangle(0, 0, layer.Width, layer.Height);
            var data = layer.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            try
            {
                int stride = Math.Abs(data.Stride);
                var buf = new byte[stride * layer.Height];
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
                var factor = new float[layer.Width];
                for (int x = 0; x < layer.Width; x++)
                {
                    float f = 1;
                    if (left > 0 && x < left) f = Math.Min(f, (x + 0.5f) / left);
                    if (right > 0 && x > layer.Width - right) f = Math.Min(f, (layer.Width - x - 0.5f) / right);
                    factor[x] = Math.Max(0, Math.Min(1, f));
                }
                for (int y = 0; y < layer.Height; y++)
                {
                    int row = y * stride;
                    for (int x = 0; x < layer.Width; x++)
                    {
                        if (factor[x] >= 1) continue;
                        int i = row + x * 4 + 3;   // BGRA
                        buf[i] = (byte)(buf[i] * factor[x]);
                    }
                }
                System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
            }
            finally { layer.UnlockBits(data); }
        }

        public void Dispose()
        {
            if (Base != null) { Base.Dispose(); Base = null; }
        }
    }
}
