using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.IO;
using System.Reflection;

namespace PearNowPlaying
{
    /// <summary>Color tokens from team-carol/carol-web (app/globals.css).</summary>
    internal static class Theme
    {
        public static readonly Color Canvas = Hex("#1a1a1c");
        public static readonly Color Surface = Hex("#242427");
        public static readonly Color Surface2 = Hex("#2e2e33");
        public static readonly Color BorderSoft = Hex("#33333a");
        public static readonly Color Border2 = Hex("#3a353d");

        public static readonly Color Ink = Hex("#f2edef");
        public static readonly Color Ink2 = Hex("#e8dfe3");
        public static readonly Color InkSoft = Hex("#cfc6ca");
        public static readonly Color Muted = Hex("#b3a8ad");
        public static readonly Color Dim = Hex("#8a8087");
        public static readonly Color Faint = Hex("#6f676c");

        public static readonly Color Accent = Hex("#ff9294");
        public static readonly Color AccentHover = Hex("#f2787b");
        public static readonly Color AccentInk = Hex("#3a1e1e");
        public static readonly Color AccentSoft = Hex("#f2b3bf");

        public static Color WithAlpha(Color c, int a)
        {
            return Color.FromArgb(Math.Max(0, Math.Min(255, a)), c.R, c.G, c.B);
        }

        static Color Hex(string h)
        {
            return Color.FromArgb(255, Convert.ToInt32(h.Substring(1, 2), 16), Convert.ToInt32(h.Substring(3, 2), 16), Convert.ToInt32(h.Substring(5, 2), 16));
        }
    }

    internal enum Weight { Regular, Medium, SemiBold }

    /// <summary>
    /// Pretendard JP (bundled, OFL-1.1): the Pretendard design carol-web uses, extended with kana and ~7,100 kanji,
    /// so Korean, Latin and Japanese lines all share one typeface. Only text with characters the font doesn't have
    /// (rare kanji, simplified Chinese, …) falls back to a system CJK font, decided from an exact glyph coverage map.
    /// </summary>
    internal static class Fonts
    {
        static readonly object Gate = new object();
        static PrivateFontCollection collection;
        static readonly Dictionary<Weight, FontFamily> pretendard = new Dictionary<Weight, FontFamily>();
        static readonly Dictionary<string, Font> cache = new Dictionary<string, Font>();
        static byte[] coverage;   // 65536-bit map of BMP code points Pretendard JP can draw
        static string jpFallback, krFallback;
        static bool initialized;

        static readonly string[] JapaneseFirst = { "Yu Gothic UI", "Meiryo UI", "Meiryo", "Noto Sans CJK JP", "Microsoft YaHei UI", "Malgun Gothic" };
        static readonly string[] KoreanFirst = { "Malgun Gothic", "맑은 고딕", "Noto Sans CJK KR", "Yu Gothic UI", "Microsoft YaHei UI" };

        static void Init()
        {
            if (initialized) return;
            initialized = true;
            var asm = Assembly.GetExecutingAssembly();
            try
            {
                collection = new PrivateFontCollection();
                var dir = Path.Combine(Config.Dir, "fonts");
                Directory.CreateDirectory(dir);
                foreach (var file in new[] { "PretendardJP-Regular.ttf", "PretendardJP-Medium.ttf" })
                {
                    var path = Path.Combine(dir, file);
                    using (var res = asm.GetManifestResourceStream(file))
                    {
                        if (res == null) continue;
                        if (!File.Exists(path) || new FileInfo(path).Length != res.Length)
                            using (var fs = File.Create(path)) res.CopyTo(fs);
                    }
                    collection.AddFontFile(path);
                }
                foreach (var fam in collection.Families)
                {
                    if (fam.Name == "Pretendard JP") pretendard[Weight.Regular] = fam;
                    else if (fam.Name == "Pretendard JP Medium") pretendard[Weight.Medium] = fam;
                }
                FontFamily medium;
                if (pretendard.TryGetValue(Weight.Medium, out medium)) pretendard[Weight.SemiBold] = medium;
            }
            catch (Exception ex) { Log.Error("font load", ex); }
            try
            {
                using (var res = asm.GetManifestResourceStream("PretendardJP-coverage.bin"))
                    if (res != null && res.Length == 8192)
                    {
                        coverage = new byte[8192];
                        int read = 0;
                        while (read < coverage.Length) { int n = res.Read(coverage, read, coverage.Length - read); if (n <= 0) break; read += n; }
                    }
            }
            catch (Exception ex) { Log.Error("font coverage", ex); coverage = null; }
            jpFallback = FirstInstalled(JapaneseFirst);
            krFallback = FirstInstalled(KoreanFirst);
        }

        static string FirstInstalled(string[] names)
        {
            foreach (var n in names)
            {
                try { using (var f = new FontFamily(n)) return f.Name; }
                catch (ArgumentException) { }
            }
            return FontFamily.GenericSansSerif.Name;
        }

        /// <param name="text">the text that will be drawn; picks a system CJK font only if Pretendard JP lacks a glyph</param>
        public static Font Get(Weight weight, float px, string text)
        {
            lock (Gate)
            {
                Init();
                FontFamily privateFamily = null;
                string systemFamily = null;
                if (!pretendard.TryGetValue(weight, out privateFamily) && !pretendard.TryGetValue(Weight.Regular, out privateFamily))
                    privateFamily = null;
                if (privateFamily == null || HasMissingGlyph(text))
                {
                    privateFamily = null;
                    systemFamily = HasHangul(text) && !HasKana(text) ? krFallback : jpFallback;
                }

                var style = FontStyle.Regular;
                if (systemFamily != null && weight == Weight.SemiBold) style = FontStyle.Bold;
                var key = (privateFamily != null ? privateFamily.Name : systemFamily) + "|" + Math.Round(px * 4) + "|" + style;
                Font f;
                if (cache.TryGetValue(key, out f)) return f;
                f = privateFamily != null
                    ? new Font(privateFamily, px, style, GraphicsUnit.Pixel)
                    : new Font(systemFamily, px, style, GraphicsUnit.Pixel);
                cache[key] = f;
                return f;
            }
        }

        static bool HasMissingGlyph(string s)
        {
            if (string.IsNullOrEmpty(s)) return false;
            foreach (var c in s)
            {
                if (char.IsSurrogate(c) || char.IsWhiteSpace(c) || char.IsControl(c)) continue;
                if (coverage != null) { if ((coverage[c >> 3] & (1 << (c & 7))) == 0) return true; }
                else if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) return true;   // no map: assume no kanji
            }
            return false;
        }

        static bool HasKana(string s)
        {
            foreach (var c in s) if (c >= 0x3040 && c <= 0x30FF) return true;
            return false;
        }

        static bool HasHangul(string s)
        {
            foreach (var c in s) if ((c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F)) return true;
            return false;
        }
    }
}
