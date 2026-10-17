using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    internal sealed class LyricLine
    {
        public int TimeMs;
        public string Text;
    }

    internal sealed class LyricsResult
    {
        public static readonly LyricsResult None = new LyricsResult { Lines = new List<LyricLine>() };
        public List<LyricLine> Lines;
        public bool Instrumental;
        /// <summary>The lookup failed (timeout, server error). Not cached, worth retrying.</summary>
        public bool Failed;
        public string Source = "";
        public bool HasSynced { get { return Lines != null && Lines.Count > 0; } }

        /// <summary>Index of the line that is active at the given time, or -1 before the first line.</summary>
        public int IndexAt(int ms)
        {
            if (!HasSynced || ms < Lines[0].TimeMs) return -1;
            int lo = 0, hi = Lines.Count - 1;
            while (lo < hi)
            {
                int mid = (lo + hi + 1) / 2;
                if (Lines[mid].TimeMs <= ms) lo = mid; else hi = mid - 1;
            }
            return lo;
        }
    }

    /// <summary>LRC parser (same rules as Pear Desktop's synced-lyrics/parsers/lrc.ts).</summary>
    internal static class Lrc
    {
        static readonly Regex Stamp = new Regex(@"^\[(\d+):(\d+)(?:[.:](\d+))?\]");
        static readonly Regex Tag = new Regex(@"^\[(\w+):\s*(.+?)\s*\]$");
        static readonly Regex WordStamp = new Regex(@"<\d+:\d+(?:[.:]\d+)?>\s*");

        public static List<LyricLine> Parse(string text)
        {
            var lines = new List<LyricLine>();
            if (string.IsNullOrEmpty(text)) return lines;
            int offset = 0;
            foreach (var raw in text.Replace("\r", "").Split('\n'))
            {
                var line = raw.Trim();
                if (!line.StartsWith("[")) continue;
                var stamps = new List<int>();
                Match m;
                while ((m = Stamp.Match(line)).Success)
                {
                    int min = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                    int sec = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
                    int ms = 0;
                    if (m.Groups[3].Success)
                    {
                        var frac = m.Groups[3].Value;
                        ms = int.Parse(frac.Length >= 3 ? frac.Substring(0, 3) : frac.PadRight(3, '0'), CultureInfo.InvariantCulture);
                    }
                    stamps.Add(min * 60000 + sec * 1000 + ms);
                    line = line.Substring(m.Length);
                }
                if (stamps.Count == 0)
                {
                    var t = Tag.Match(line);
                    int o;
                    if (t.Success && t.Groups[1].Value == "offset" && int.TryParse(t.Groups[2].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out o))
                        offset = o;
                    continue;
                }
                var body = WordStamp.Replace(line, "").Trim();
                foreach (var st in stamps) lines.Add(new LyricLine { TimeMs = st, Text = body });
            }
            // applied the same way as Pear Desktop's parser
            if (offset != 0) foreach (var l in lines) l.TimeMs = Math.Max(0, l.TimeMs + offset);
            return lines.OrderBy(l => l.TimeMs).ToList();
        }
    }

    /// <summary>
    /// Looks lyrics up on LRCLIB (https://lrclib.net), the open lyrics database Pear Desktop's
    /// synced-lyrics plugin also uses. Matching follows Pear's provider: artist similarity
    /// (Jaro-Winkler &gt; 0.9, tags as a fallback) and the closest duration within 15 seconds.
    /// </summary>
    internal sealed class LyricsProvider : IDisposable
    {
        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly Dictionary<string, LyricsResult> cache = new Dictionary<string, LyricsResult>();
        readonly object gate = new object();
        public string BaseUrl;

        public LyricsProvider(string baseUrl)
        {
            BaseUrl = (baseUrl ?? "https://lrclib.net").TrimEnd('/');
            http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PearNowPlaying/1.4.3 (+https://github.com/Roena0516/pear-now-playing)");
        }

        public async Task<LyricsResult> Find(SongInfo song, CancellationToken ct)
        {
            var key = song.VideoId + "|" + song.Title;
            lock (gate) { LyricsResult hit; if (cache.TryGetValue(key, out hit)) return hit; }

            LyricsResult result = LyricsResult.None;
            string how = "not found";
            try
            {
                // 1) exact signature lookup (artist + title + album + duration): one row, usually fast
                var best = await Get(song, ct);
                if (best != null) how = "get";

                // 2) search like Pear does, then looser free-text searches
                var seen = new List<IDictionary<string, object>>();
                if (best == null)
                {
                    var q = new List<KeyValuePair<string, string>>
                    {
                        new KeyValuePair<string, string>("artist_name", song.Artist),
                        new KeyValuePair<string, string>("track_name", song.Title),
                    };
                    if (!string.IsNullOrEmpty(song.Album)) q.Add(new KeyValuePair<string, string>("album_name", song.Album));
                    var items = await Search(q, ct);
                    seen.AddRange(items);
                    best = Pick(items, song);
                    if (best != null) how = "search";
                }
                if (best == null)
                {
                    var alt = string.IsNullOrEmpty(song.AltTitle) ? song.Title : song.AltTitle;
                    foreach (var text in new[] { alt + " " + FirstArtist(song.Artist), CleanTitle(song.Title) + " " + FirstArtist(song.Artist), CleanTitle(alt) }.Distinct())
                    {
                        if (string.IsNullOrWhiteSpace(text)) continue;
                        var items = await Search(new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("q", text.Trim()) }, ct);
                        seen.AddRange(items);
                        best = Pick(items, song);
                        if (best != null) { how = "q=" + text.Trim(); break; }
                    }
                }

                // 3) artist written differently (e.g. "Kenshi Yonezu" vs "米津玄師"): same title and nearly the same length
                if (best == null)
                {
                    best = PickByTitle(seen, song);
                    if (best != null) how = "title match (" + Str(best, "artistName") + ")";
                }

                if (best != null)
                {
                    if (Bool(best, "instrumental")) result = new LyricsResult { Lines = new List<LyricLine>(), Instrumental = true, Source = "LRCLIB" };
                    else result = new LyricsResult { Lines = Lrc.Parse(Str(best, "syncedLyrics")), Source = "LRCLIB" };
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }   // song changed
            catch (Exception ex)
            {
                // timeouts land here too (HttpClient reports them as TaskCanceledException)
                Log.Write("WARN lyrics lookup failed for " + song.Artist + " - " + song.Title + ": "
                          + (ex is OperationCanceledException ? "timeout" : ex.GetType().Name + ": " + ex.Message));
                return new LyricsResult { Lines = new List<LyricLine>(), Failed = true };   // don't cache
            }
            Log.Info("lyrics " + (result.HasSynced ? "found via " + how : result.Instrumental ? "instrumental" : "not found")
                     + ": " + song.Artist + " - " + song.Title + " (" + (int)song.Duration + "s)");
            lock (gate) cache[key] = result;
            return result;
        }

        /// <summary>Drop the cached result for a song so the next Find asks LRCLIB again.</summary>
        public void Forget(SongInfo song)
        {
            lock (gate) cache.Remove(song.VideoId + "|" + song.Title);
        }

        /// <summary>
        /// GET with one quick retry when LRCLIB is busy (429/502/503/504). It is a free, volunteer-run
        /// service whose search endpoint answers 503 fairly often under load; keep the request count low.
        /// </summary>
        async Task<HttpResponseMessage> Send(string url, CancellationToken ct)
        {
            var waits = new[] { 2000 };   // one quick retry; the caller retries the whole lookup later
            for (int i = 0; ; i++)
            {
                var resp = await http.GetAsync(url, ct);
                int code = (int)resp.StatusCode;
                bool busy = code == 429 || code == 502 || code == 503 || code == 504;
                if (!busy || i >= waits.Length) return resp;
                int wait = waits[i];
                if (resp.Headers.RetryAfter != null && resp.Headers.RetryAfter.Delta.HasValue)
                    wait = (int)Math.Min(10000, Math.Max(wait, resp.Headers.RetryAfter.Delta.Value.TotalMilliseconds));
                resp.Dispose();
                await Task.Delay(wait, ct);
            }
        }

        async Task<IDictionary<string, object>> Get(SongInfo song, CancellationToken ct)
        {
            if (string.IsNullOrEmpty(song.Title) || string.IsNullOrEmpty(song.Artist) || song.Duration <= 0) return null;
            var url = BaseUrl + "/api/get?artist_name=" + Uri.EscapeDataString(song.Artist)
                    + "&track_name=" + Uri.EscapeDataString(song.Title)
                    + "&album_name=" + Uri.EscapeDataString(song.Album ?? "")
                    + "&duration=" + ((int)Math.Round(song.Duration)).ToString(CultureInfo.InvariantCulture);
            using (var resp = await Send(url, ct))
            {
                if ((int)resp.StatusCode == 404) return null;
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("LRCLIB get " + (int)resp.StatusCode);
                var d = json.DeserializeObject(await resp.Content.ReadAsStringAsync()) as IDictionary<string, object>;
                if (d == null) return null;
                return !string.IsNullOrEmpty(Str(d, "syncedLyrics")) || Bool(d, "instrumental") ? d : null;
            }
        }

        async Task<List<IDictionary<string, object>>> Search(List<KeyValuePair<string, string>> query, CancellationToken ct)
        {
            var sb = new StringBuilder(BaseUrl + "/api/search?");
            for (int i = 0; i < query.Count; i++)
            {
                if (i > 0) sb.Append('&');
                sb.Append(query[i].Key).Append('=').Append(Uri.EscapeDataString(query[i].Value ?? ""));
            }
            using (var resp = await Send(sb.ToString(), ct))
            {
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("LRCLIB search " + (int)resp.StatusCode);
                var body = await resp.Content.ReadAsStringAsync();
                var arr = json.DeserializeObject(body) as IEnumerable;
                var list = new List<IDictionary<string, object>>();
                if (arr != null) foreach (var o in arr) { var d = o as IDictionary<string, object>; if (d != null) list.Add(d); }
                return list;
            }
        }

        static IDictionary<string, object> Pick(List<IDictionary<string, object>> items, SongInfo song)
        {
            var ours = ArtistVariants(song.Artist);
            var tags = (song.Tags ?? new List<string>()).Select(t => t.ToLowerInvariant()).Where(t => !ours.Contains(t)).ToList();
            var candidates = new List<IDictionary<string, object>>();
            foreach (var it in items)
            {
                var theirs = ArtistVariants(Str(it, "artistName"));
                double ratio = 0;
                foreach (var a in ours) foreach (var b in theirs) ratio = Math.Max(ratio, JaroWinkler(a, b));
                if (ratio <= 0.9 && tags.Count > 0)
                    foreach (var a in tags) foreach (var b in theirs) ratio = Math.Max(ratio, JaroWinkler(a, b));
                if (ratio > 0.9) candidates.Add(it);
            }
            if (song.Duration > 0)
                candidates = candidates.Where(c => Math.Abs(Num(c, "duration") - song.Duration) <= 15)
                                       .OrderBy(c => Math.Abs(Num(c, "duration") - song.Duration)).ToList();
            // prefer entries that actually have timestamps
            return candidates.FirstOrDefault(c => !string.IsNullOrEmpty(Str(c, "syncedLyrics")))
                ?? candidates.FirstOrDefault(c => Bool(c, "instrumental"));
        }

        /// <summary>
        /// Fallback when the artist name doesn't match: the title must be the same (ignoring case, spaces
        /// and punctuation) and the length within 3 seconds, which together are very unlikely to collide.
        /// </summary>
        static IDictionary<string, object> PickByTitle(List<IDictionary<string, object>> items, SongInfo song)
        {
            if (song.Duration <= 0) return null;
            var titles = new HashSet<string> { Norm(song.Title), Norm(CleanTitle(song.Title)) };
            if (!string.IsNullOrEmpty(song.AltTitle)) { titles.Add(Norm(song.AltTitle)); titles.Add(Norm(CleanTitle(song.AltTitle))); }
            titles.Remove("");
            return items
                .Where(it => !string.IsNullOrEmpty(Str(it, "syncedLyrics")))
                .Where(it => titles.Contains(Norm(Str(it, "trackName"))))
                .Where(it => Math.Abs(Num(it, "duration") - song.Duration) <= 3)
                .OrderBy(it => Math.Abs(Num(it, "duration") - song.Duration))
                .FirstOrDefault();
        }

        static string Norm(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new StringBuilder();
            foreach (var ch in s.Normalize(NormalizationForm.FormKC).ToLowerInvariant())
                if (char.IsLetterOrDigit(ch)) sb.Append(ch);
            return sb.ToString();
        }

        /// <summary>"비비 (BIBI) & 윤하" -> {"비비 (bibi)", "비비", "bibi", "윤하"}</summary>
        static HashSet<string> ArtistVariants(string artist)
        {
            var set = new HashSet<string>();
            if (string.IsNullOrEmpty(artist)) return set;
            foreach (var part in Regex.Split(artist, @"\s*(?:[&,、/×]|\bfeat\.?|\bft\.?|\bx\b|\band\b|\s및\s|\sと\s)\s*", RegexOptions.IgnoreCase))
            {
                var p = part.Trim().ToLowerInvariant();
                if (p.Length == 0) continue;
                set.Add(p);
                var m = Regex.Match(p, @"^(.*?)\s*[\(\[](.+?)[\)\]]\s*$");
                if (m.Success)
                {
                    if (m.Groups[1].Value.Trim().Length > 0) set.Add(m.Groups[1].Value.Trim());
                    set.Add(m.Groups[2].Value.Trim());
                }
            }
            return set;
        }

        static string FirstArtist(string artist)
        {
            var v = ArtistVariants(artist);
            return v.Count > 0 ? v.First() : "";
        }

        internal static string CleanTitleForTest(string title) { return CleanTitle(title); }

        static string CleanTitle(string title)
        {
            if (string.IsNullOrEmpty(title)) return "";
            // video uploads: "【歌ってみた】曲名 / covered by 誰か", "曲名【MV】", "Title (Official Video)"
            var t = Regex.Replace(title, @"【[^】]*】", " ");
            t = Regex.Replace(t, @"[\(\[][^\)\]]*(official|mv|m/v|video|audio|lyric|live|ver\.|version|feat|prod|cover|歌ってみた|踊ってみた|弾いてみた)[^\)\]]*[\)\]]", " ", RegexOptions.IgnoreCase);
            t = Regex.Replace(t, @"\s*/?\s*(covered by|cover by)\b.*$", "", RegexOptions.IgnoreCase);
            t = Regex.Replace(t, @"歌ってみた|踊ってみた|弾いてみた", " ");
            t = Regex.Replace(t, @"[\s\u3000]+", " ").Trim();
            return t.Trim('/', '-', '|', ' ');
        }

        internal static double JaroWinkler(string a, string b)
        {
            if (a == b) return 1;
            int la = a.Length, lb = b.Length;
            if (la == 0 || lb == 0) return 0;
            int range = Math.Max(0, Math.Max(la, lb) / 2 - 1);
            var ma = new bool[la]; var mb = new bool[lb];
            int matches = 0;
            for (int i = 0; i < la; i++)
            {
                int lo = Math.Max(0, i - range), hi = Math.Min(i + range + 1, lb);
                for (int j = lo; j < hi; j++)
                {
                    if (mb[j] || a[i] != b[j]) continue;
                    ma[i] = mb[j] = true; matches++; break;
                }
            }
            if (matches == 0) return 0;
            int t = 0, k = 0;
            for (int i = 0; i < la; i++)
            {
                if (!ma[i]) continue;
                while (!mb[k]) k++;
                if (a[i] != b[k]) t++;
                k++;
            }
            double m = matches;
            double jaro = (m / la + m / lb + (m - t / 2.0) / m) / 3.0;
            int prefix = 0;
            for (int i = 0; i < Math.Min(4, Math.Min(la, lb)); i++) { if (a[i] == b[i]) prefix++; else break; }
            return jaro + prefix * 0.1 * (1 - jaro);
        }

        static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }

        static double Num(IDictionary<string, object> d, string k)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null) return 0;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return 0; }
        }

        static bool Bool(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is bool && (bool)v;
        }

        public void Dispose() { http.Dispose(); }
    }
}
