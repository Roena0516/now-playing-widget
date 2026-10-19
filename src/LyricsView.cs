using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace PearNowPlaying
{
    /// <summary>
    /// Scrolling lyrics panel in the style of the YouTube Music mobile app: all lines share one size,
    /// the current line is bright and the rest are dim, and on every line change the list glides up
    /// (ease-out) while the highlight crossfades. Lines near the top/bottom edge fade out.
    /// Drawn in carol-web colors with the 3px accent rule beside the current line.
    /// </summary>
    internal sealed class LyricsView
    {
        sealed class Entry
        {
            public string Text;
            public bool Gap;
            public List<string> Lines;
            public Font Font;
            public float LineH;
            public float Y;       // top within the content column
            public float H;
        }

        const double ScrollMs = 460, JumpMs = 260;

        readonly List<Entry> entries = new List<Entry>();
        int leadingPseudo;          // 1 when a "♪" line was added before the first lyric
        int carried;                // lines kept from the previous song above this song's first line
        int ownEnd;                 // this song's entries end here; the next song's (SetNext) follow
        bool mergedGap;             // this song's opening "♪" is the last kept line of the previous song's
        float s;
        int width, height, padX, padY, textX, textW;
        float gapY, viewportH, anchor;

        int current = -1, previous = -1;
        float scrollFrom, scrollTo;
        readonly Stopwatch anim = new Stopwatch();
        double animMs = ScrollMs;

        public int Width { get { return width; } }
        public int Height { get { return height; } }
        public bool HasLines { get { return ownEnd > carried || mergedGap; } }
        int FirstOwn { get { return mergedGap ? carried - 1 : carried; } }
        public bool Animating { get { return anim.IsRunning && anim.Elapsed.TotalMilliseconds < animMs; } }

        /// <summary>
        /// Lay the song's lines out for the given panel width (in device pixels). With carryOver (the next song's
        /// lyrics replacing the last song's while the panel stays open), the line that was current and the one before
        /// it stay above the new first line, still highlighted, so the next SetCurrent scrolls on into the new song
        /// instead of the list restarting at the top. When the last song was at its end, its remaining lines stay
        /// too, so the new song's lines land exactly where SetNext had already shown them.
        /// </summary>
        public void SetLines(List<LyricLine> lines, double scale, int panelWidth, bool carryOver = false)
        {
            var keep = new List<Entry>();
            int keptCurrent = -1;
            if (carryOver && current >= FirstOwn && current < ownEnd && (float)scale == s && panelWidth == width)
            {
                int from = Math.Max(FirstOwn, current - 1);
                int to = ownEnd - 1 - current <= NextShownWithin ? ownEnd - 1 : current;
                for (int i = from; i <= to; i++) keep.Add(entries[i]);
                keptCurrent = current - from;
            }
            entries.Clear();
            current = previous = -1;
            carried = 0;
            mergedGap = false;
            anim.Reset();
            s = (float)scale;
            width = panelWidth;
            padX = R(16 * s);
            padY = R(12 * s);
            textX = padX + R(3 * s) + R(12 * s);
            textW = Math.Max(R(120 * s), width - textX - padX);
            gapY = 8 * s;

            leadingPseudo = lines.Count > 0 && lines[0].TimeMs > 0 ? 1 : 0;
            // the last song ending on "♪" and this one opening with one: a single "♪" line, not two in a row
            mergedGap = keep.Count > 0 && keep[keep.Count - 1].Gap && StartsWithGap(lines);
            entries.AddRange(Layout(lines, 0, mergedGap));
            ownEnd = entries.Count;

            if (keep.Count > 0)
            {
                // the kept lines end one gap above the new first line
                float y = -gapY;
                for (int i = keep.Count - 1; i >= 0; i--) { y -= keep[i].H; keep[i].Y = y; y -= gapY; }
                entries.InsertRange(0, keep);
                carried = keep.Count;
                ownEnd += carried;
            }

            // viewport: a peek of the previous line, up to two lines for the current one, and what follows
            float lineHRef;
            using (var probe = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(probe))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                lineHRef = CardRenderer.LineHeight(Fonts.Get(Weight.Medium, 18f * s, "가"), g);
            }
            anchor = (float)Math.Round(lineHRef * 0.9f + gapY);
            viewportH = (float)Math.Round(anchor + lineHRef * 3 + gapY * 2);
            height = (int)Math.Ceiling(padY * 2 + viewportH);

            if (carried > 0)
            {
                // still on the last song's line; the first SetCurrent glides from here
                current = keptCurrent;
                scrollFrom = scrollTo = entries[current].Y - anchor;
            }
        }

        /// <summary>The lines below the current one that the viewport shows (the next song's are seen this close to the end).</summary>
        const int NextShownWithin = 3;

        /// <summary>
        /// The next song's lines (fetched ahead) below this song's last line, so near the end of a song its
        /// successor is already in view and the change just scrolls on. Null or empty takes them away.
        /// </summary>
        public void SetNext(List<LyricLine> next)
        {
            if (entries.Count > ownEnd) entries.RemoveRange(ownEnd, entries.Count - ownEnd);
            if (next == null || next.Count == 0 || ownEnd == 0) return;
            var last = entries[ownEnd - 1];
            entries.AddRange(Layout(next, last.Y + last.H + gapY, last.Gap && StartsWithGap(next)));
        }

        /// <summary>The song's first panel line is a "♪" (it opens with music, or with a blank line).</summary>
        static bool StartsWithGap(List<LyricLine> lines)
        {
            return lines.Count > 0 && (lines[0].TimeMs > 0 || IsGap(lines[0].Text));
        }

        static bool IsGap(string text) { return string.IsNullOrWhiteSpace(text) || text.Trim() == "♪"; }

        /// <summary>
        /// Entries for a song's lines from y down, with a "♪" line first if the song starts with music.
        /// skipFirst leaves that first "♪" out (the line above already is one).
        /// </summary>
        List<Entry> Layout(List<LyricLine> lines, float y, bool skipFirst = false)
        {
            var texts = new List<string>();
            if (lines.Count > 0 && lines[0].TimeMs > 0) texts.Add("");
            foreach (var l in lines) texts.Add(l.Text ?? "");
            if (skipFirst && texts.Count > 0) texts.RemoveAt(0);
            var result = new List<Entry>();
            using (var probe = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(probe))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                foreach (var t in texts)
                {
                    var e = new Entry { Gap = IsGap(t) };
                    e.Text = e.Gap ? "♪" : t.Trim();
                    e.Font = Fonts.Get(Weight.Medium, 18f * s, e.Text);
                    e.LineH = CardRenderer.LineHeight(e.Font, g);
                    e.Lines = CardRenderer.Wrap(g, e.Text, e.Font, textW, 2);
                    e.Y = y;
                    e.H = e.LineH * e.Lines.Count;
                    y += e.H + gapY;
                    result.Add(e);
                }
            }
            return result;
        }

        /// <summary>Map an index from LyricsResult.IndexAt (-1 = before the first line) to a panel entry.</summary>
        public int EntryFor(int lyricIndex)
        {
            if (ownEnd == FirstOwn) return -1;
            // with mergedGap, the song's own first line (its "♪") is the kept one just above
            int e = FirstOwn + (lyricIndex < 0 ? 0 : lyricIndex + leadingPseudo);
            return Math.Max(FirstOwn, Math.Min(ownEnd - 1, e));
        }

        public int Current { get { return current; } }

        /// <summary>Move the highlight. With animate=false it snaps (first show, after a seek while hidden).</summary>
        public void SetCurrent(int entry, bool animate)
        {
            if (entry == current || entry < 0 || entry >= entries.Count) return;
            float target = entries[entry].Y - anchor;
            if (!animate || current < 0)
            {
                previous = -1;
                current = entry;
                scrollFrom = scrollTo = target;
                anim.Reset();
                return;
            }
            scrollFrom = CurrentScroll();   // start from wherever we are, even mid-animation
            scrollTo = target;
            previous = current;
            current = entry;
            animMs = Math.Abs(entry - previous) > 2 && previous >= carried ? JumpMs : ScrollMs;
            anim.Restart();
        }

        float Progress
        {
            get
            {
                if (!anim.IsRunning) return 1;
                double t = Math.Min(1, anim.Elapsed.TotalMilliseconds / animMs);
                return (float)(1 - Math.Pow(1 - t, 3));   // ease-out cubic
            }
        }

        float CurrentScroll() { return scrollFrom + (scrollTo - scrollFrom) * Progress; }

        public Bitmap Render(bool paused, double opacity)
        {
            var bmp = new Bitmap(Math.Max(1, width), Math.Max(1, height), PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;

                int a = Math.Max(0, Math.Min(255, (int)Math.Round(255 * opacity)));
                using (var path = CardRenderer.Rounded(new RectangleF(0.5f, 0.5f, width - 1, height - 1), 16 * s))
                {
                    using (var bg = new SolidBrush(Theme.WithAlpha(Theme.Surface, a))) g.FillPath(bg, path);
                    using (var border = new Pen(Theme.WithAlpha(Theme.BorderSoft, Math.Min(255, a + 20)), 1f)) g.DrawPath(border, path);
                }
                if (entries.Count == 0 || current < 0) return bmp;

                float t = Progress;
                float scroll = CurrentScroll();
                float top = padY;
                var viewport = new RectangleF(textX - 2, top, textW + 6, viewportH);

                // accent rule beside the current line; its height eases from the old line's to the new one's
                float curH = entries[current].H;
                float barH = previous >= 0 ? entries[previous].H + (curH - entries[previous].H) * t : curH;
                float barW = Math.Max(2f, 3 * s);
                using (var bar = CardRenderer.Rounded(new RectangleF(padX, top + anchor, barW, barH), barW / 2))
                using (var bb = new SolidBrush(paused ? Theme.Faint : Theme.Accent))
                    g.FillPath(bb, bar);

                var state = g.Save();
                g.SetClip(viewport);
                float fadeZone = Math.Max(1, anchor);
                for (int i = 0; i < entries.Count; i++)
                {
                    var e = entries[i];
                    float y = top + e.Y - scroll;
                    if (y + e.H < top - 1 || y > top + viewportH + 1) continue;

                    // highlight: 1 for the current line, crossfading with the line we just left
                    float hl = i == current ? (previous >= 0 ? t : 1f) : (i == previous ? 1f - t : 0f);
                    var bright = paused ? Theme.InkSoft : Theme.Ink;
                    var dim = Theme.Dim;
                    var color = e.Gap ? dim : Lerp(dim, bright, hl);

                    // fade lines out as they approach the top/bottom edge of the viewport
                    float center = y + e.LineH / 2 - top;
                    float edge = Math.Min(center, viewportH - center);
                    float fade = Smooth(Math.Max(0, Math.Min(1, edge / fadeZone)));
                    int alpha = (int)Math.Round(255 * fade * (0.8f + 0.2f * hl));
                    if (alpha <= 2) continue;

                    using (var brush = new SolidBrush(Color.FromArgb(Math.Min(255, alpha), color)))
                    using (var sf = new StringFormat(StringFormatFlags.NoWrap))
                    {
                        float ly = y;
                        foreach (var line in e.Lines)
                        {
                            g.DrawString(line, e.Font, brush, new RectangleF(textX, ly, textW + 4, e.LineH + 2), sf);
                            ly += e.LineH;
                        }
                    }
                }
                g.Restore(state);
            }
            return bmp;
        }

        static Color Lerp(Color a, Color b, float t)
        {
            t = Math.Max(0, Math.Min(1, t));
            return Color.FromArgb(255,
                (int)Math.Round(a.R + (b.R - a.R) * t),
                (int)Math.Round(a.G + (b.G - a.G) * t),
                (int)Math.Round(a.B + (b.B - a.B) * t));
        }

        static float Smooth(float x) { return x * x * (3 - 2 * x); }
        static int R(float v) { return (int)Math.Round(v); }
    }
}
