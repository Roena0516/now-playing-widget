using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    /// <summary>
    /// Times a cover's lyrics by the video's captions. A cover gets its original's lyrics, and the singing often starts
    /// a little earlier or later than the original's (measured 2026-11-15 on 14 歌ってみた videos: -0.9 s to +2.4 s, most
    /// +0.2 to +1 s). The captions' lines are matched to the lyrics' lines near the same time, and the offset most of the
    /// matches agree on is used. Caption text is only compared here: never kept, shown or logged; only the offset is kept
    /// (CaptionTimingStore). The macOS version is CaptionTiming.swift, with the same rules.
    /// </summary>
    internal static class CaptionTiming
    {
        /// <summary>How far from a lyric line its caption may be (ms).</summary>
        public const int Window = 15000;
        /// <summary>Characters of each lyric line compared (its beginning).</summary>
        public const int Prefix = 8;
        public const double MinScore = 0.75;
        /// <summary>Offsets this close (ms) count as agreeing.</summary>
        public const int Agree = 250;
        public const int MinAgreeing = 4;

        /// <summary>Lyrics from another recording than the video: a cover's original, or an MV's official audio.</summary>
        public static bool Applies(LyricsResult r)
        {
            if (r == null || !r.HasSynced) return false;
            var s = r.Source ?? "";
            return s.Contains("원곡") || s.Contains("공식 음원");
        }

        /// <summary>
        /// A cover's original's lyrics ("… · 원곡", "… · 원곡 검색"). These go without the default lead (lyricsOffsetMs'
        /// default, 0.3 s early): the user found covers' lyrics too early with it (2026-11-15).
        /// </summary>
        public static bool IsCover(LyricsResult r)
        {
            return r != null && r.HasSynced && (r.Source ?? "").Contains("원곡");
        }

        /// <summary>
        /// Lyrics shown without the default lead (lyricsOffsetMs' default, 0.3 s early; only the user's change to it
        /// stays): YouTube Music's own (timed to the recording, they matched its app only without the lead, 2026-11-20),
        /// and a cover's original's the captions didn't time (covers mostly sing a little later than the original).
        /// </summary>
        public static bool WithoutLead(LyricsResult r, bool timedByCaptions)
        {
            if (r == null || !r.HasSynced) return false;
            return (r.Source ?? "").StartsWith("YouTube Music", StringComparison.Ordinal) || (IsCover(r) && !timedByCaptions);
        }

        /// <summary>Identifies the lyrics an offset was measured against (a re-lookup may bring other lyrics).</summary>
        public static string LyricsKey(LyricsResult r)
        {
            var l = r.Lines;
            return l.Count + ":" + l[0].TimeMs + ":" + l[l.Count - 1].TimeMs;
        }

        /// <summary>
        /// How much later (ms) the video sings than the lyrics' times, or null when the captions don't settle it:
        /// fewer than MinAgreeing matched lines agree within Agree ms, or they are fewer than half the matches.
        /// </summary>
        public static int? Estimate(IList<LyricLine> lyrics, IList<LyricLine> captions)
        {
            var chars = new StringBuilder();
            var times = new List<int>();
            foreach (var c in captions)
            {
                var n = Norm(c.Text);
                chars.Append(n);
                for (int i = 0; i < n.Length; i++) times.Add(c.TimeMs);
            }
            var text = chars.ToString();
            var offsets = new List<int>();
            foreach (var line in lyrics)
            {
                var p = Norm(line.Text);
                if (p.Length > Prefix) p = p.Substring(0, Prefix);
                if (p.Length < 3) continue;
                double best = 0;
                int bestOffset = 0;
                for (int j = 0; j + p.Length <= text.Length; j++)
                {
                    // only from where a caption line (auto captions: a word) starts, near the lyric's time
                    if (Math.Abs(times[j] - line.TimeMs) > Window || (j > 0 && times[j - 1] == times[j])) continue;
                    double r = Similarity(p, text.Substring(j, p.Length));
                    if (r > best) { best = r; bestOffset = times[j] - line.TimeMs; }
                }
                if (best >= MinScore) offsets.Add(bestOffset);
            }
            if (offsets.Count == 0) return null;
            // the offset the most matches agree with (the smaller one on a tie)
            int center = offsets[0], most = -1;
            foreach (var c in offsets)
            {
                int n = offsets.Count(x => Math.Abs(x - c) <= Agree);
                if (n > most || (n == most && Math.Abs(c) < Math.Abs(center))) { most = n; center = c; }
            }
            var cluster = offsets.Where(x => Math.Abs(x - center) <= Agree).OrderBy(x => x).ToList();
            if (cluster.Count < MinAgreeing || cluster.Count * 2 < offsets.Count) return null;
            int m = cluster.Count / 2;
            return cluster.Count % 2 == 1 ? cluster[m] : (int)Math.Round((cluster[m - 1] + cluster[m]) / 2.0);
        }

        static readonly Regex Bracketed = new Regex(@"[\[(（【].*?[\])）】]");

        /// <summary>Letters and digits only, lower case, katakana as hiragana, without bracketed parts ("[音楽]").</summary>
        public static string Norm(string s)
        {
            s = Bracketed.Replace((s ?? "").Normalize(NormalizationForm.FormKC).ToLowerInvariant(), "");
            var sb = new StringBuilder(s.Length);
            foreach (var ch0 in s)
            {
                var ch = ch0;
                if (ch >= 'ァ' && ch <= 'ヶ') ch = (char)(ch - 0x60);
                if (char.IsLetterOrDigit(ch)) sb.Append(ch);
            }
            return sb.ToString();
        }

        /// <summary>2 × the longest common subsequence / both lengths (1 = the same).</summary>
        public static double Similarity(string a, string b)
        {
            if (a.Length + b.Length == 0) return 0;
            var prev = new int[b.Length + 1];
            var cur = new int[b.Length + 1];
            foreach (var ca in a)
            {
                for (int k = 0; k < b.Length; k++)
                    cur[k + 1] = ca == b[k] ? prev[k] + 1 : Math.Max(prev[k + 1], cur[k]);
                var t = prev; prev = cur; cur = t;
            }
            return 2.0 * prev[b.Length] / (a.Length + b.Length);
        }

        /// <summary>The lyrics' language as caption tracks name it: ja, ko, zh or en.</summary>
        public static string Language(IList<LyricLine> lyrics)
        {
            int kana = 0, hangul = 0, han = 0, latin = 0;
            foreach (var l in lyrics)
                foreach (var ch in l.Text ?? "")
                {
                    if ((ch >= '぀' && ch <= 'ヿ')) kana++;
                    else if (ch >= '가' && ch <= '힣') hangul++;
                    else if (ch >= '一' && ch <= '鿿') han++;
                    else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) latin++;
                }
            int letters = Math.Max(1, kana + hangul + han + latin);
            if (kana * 20 >= letters) return "ja";
            if (hangul >= han && hangul >= latin && hangul > 0) return "ko";
            if (han >= latin && han > 0) return "zh";
            return "en";
        }

        /// <summary>
        /// The offset for a video by its captions in the lyrics' language (uploaded ones first, then auto ones), or null
        /// when none settles it. Throws when YouTube can't be reached (not to be remembered as "none").
        /// </summary>
        public static async Task<int?> Find(YtmLyrics yt, string videoId, LyricsResult lyrics, CancellationToken ct)
        {
            var lang = Language(lyrics.Lines);
            var tracks = (await yt.CaptionTracks(videoId, ct))
                .Where(t => t.Language == lang || t.Language.StartsWith(lang + "-", StringComparison.Ordinal))
                .OrderBy(t => t.Auto).Take(2).ToList();
            foreach (var t in tracks)
            {
                var offset = Estimate(lyrics.Lines, await yt.CaptionLines(t, ct));
                if (offset.HasValue)
                {
                    Log.Info("caption timing " + videoId + ": " + (offset.Value >= 0 ? "+" : "") + offset.Value + " ms (" + t.Language + (t.Auto ? " auto" : "") + ")");
                    return offset;
                }
            }
            Log.Info("caption timing " + videoId + ": not settled (" + tracks.Count + " " + lang + " track(s))");
            return null;
        }
    }

    /// <summary>
    /// Caption timings found (and "none"s), so a cover isn't measured again every time it plays. Only the video ID, the
    /// lyrics it was measured against (CaptionTiming.LyricsKey) and the offset are kept, in caption-timing.json next to
    /// the lyrics cache; entries older than 30 days are measured again (captions may have been added).
    /// </summary>
    internal sealed class CaptionTimingStore
    {
        public static readonly string DefaultPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PearNowPlaying", "caption-timing.json");
        const int Version = 1, MaxDays = 30, MaxEntries = 3000;

        sealed class Entry { public string Id, Lyrics; public int? Ms; public int Day; }

        readonly string path;
        readonly object gate = new object();
        readonly List<Entry> entries = new List<Entry>();   // oldest first

        public CaptionTimingStore(string path) { this.path = path; Load(); }

        static int Today { get { return (int)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalDays; } }

        /// <summary>True when the video was measured against these lyrics; ms is null when it didn't settle.</summary>
        public bool TryGet(string videoId, string lyricsKey, out int? ms)
        {
            lock (gate)
            {
                var e = entries.FirstOrDefault(x => x.Id == videoId && x.Lyrics == lyricsKey && Today - x.Day <= MaxDays);
                ms = e != null ? e.Ms : null;
                return e != null;
            }
        }

        public void Set(string videoId, string lyricsKey, int? ms)
        {
            lock (gate)
            {
                entries.RemoveAll(x => x.Id == videoId);
                entries.Add(new Entry { Id = videoId, Lyrics = lyricsKey, Ms = ms, Day = Today });
                entries.RemoveAll(x => Today - x.Day > MaxDays);
                while (entries.Count > MaxEntries) entries.RemoveAt(0);
                Save();
            }
        }

        public void Forget(string videoId) { lock (gate) { if (entries.RemoveAll(x => x.Id == videoId) > 0) Save(); } }

        void Load()
        {
            try
            {
                if (!File.Exists(path)) return;
                var d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as IDictionary<string, object>;
                object list;
                if (d == null || !d.TryGetValue("videos", out list) || !(list is IEnumerable)) return;
                foreach (var e in ((IEnumerable)list).OfType<IDictionary<string, object>>())
                {
                    object id, lyrics, ms, day;
                    if (!e.TryGetValue("id", out id) || !LyricsTiming.CanKeep(id as string) || !e.TryGetValue("lyrics", out lyrics) || !(lyrics is string)
                        || !e.TryGetValue("day", out day) || !(day is int)) continue;
                    e.TryGetValue("ms", out ms);
                    entries.Add(new Entry { Id = (string)id, Lyrics = (string)lyrics, Ms = ms is int ? (int?)Math.Max(-LyricsTiming.Limit, Math.Min(LyricsTiming.Limit, (int)ms)) : null, Day = (int)day });
                }
            }
            catch (Exception ex) { Log.Write("WARN caption timing file unreadable: " + ex.Message); }
        }

        void Save()
        {
            try
            {
                var d = new Dictionary<string, object>
                {
                    { "version", Version },
                    { "videos", entries.Select(e => new Dictionary<string, object> { { "id", e.Id }, { "lyrics", e.Lyrics }, { "ms", e.Ms }, { "day", e.Day } }).ToList() },
                };
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, new JavaScriptSerializer().Serialize(d), new UTF8Encoding(false));
            }
            catch (Exception ex) { Log.Write("WARN caption timing not saved: " + ex.Message); }
        }
    }
}
