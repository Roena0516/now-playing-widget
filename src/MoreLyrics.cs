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
    /// <summary>
    /// Synced lyrics from Kugou and NetEase Cloud Music, asked only when LRCLIB has none for the song (or is busy).
    /// Both are unofficial endpoints the music apps use themselves, answered without signing in; either may stop
    /// working at any time, so a source that keeps failing is skipped for a while and the lookup goes on without it.
    /// Their catalogs hold many songs LRCLIB lacks (vocaloid, utaite, Korean and Chinese releases), but also covers and
    /// remixes under the same name: a result must have the song's title and be by its artist (or, where the caller
    /// allows it, have the exact title and length), and its lyrics must fit the song's length.
    /// </summary>
    internal sealed class MoreLyrics : IDisposable
    {
        internal sealed class Candidate
        {
            public string Source, Id, Key, Title, Artist;
            public double Duration;
        }

        sealed class Source
        {
            public string Name;
            public int Failures;
            public DateTime SkipUntil = DateTime.MinValue;
            public bool Paused { get { return DateTime.UtcNow < SkipUntil; } }
        }

        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly object gate = new object();
        readonly Source kugou = new Source { Name = "Kugou" }, netease = new Source { Name = "NetEase" };
        readonly Dictionary<string, LyricsResult> memo = new Dictionary<string, LyricsResult>();
        public string KugouBase = "https://lyrics.kugou.com", NeteaseBase = "https://music.163.com";

        public MoreLyrics()
        {
            http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("NowPlayingWidget/" + AppInfo.Version + " (+https://github.com/Roena0516/now-playing-widget)");
        }

        /// <summary>"Find lyrics again": ask the sources even if they were failing.</summary>
        public void ResetPause()
        {
            lock (gate) foreach (var s in new[] { kugou, netease }) { s.Failures = 0; s.SkipUntil = DateTime.MinValue; }
        }

        /// <summary>
        /// Kugou first (its search takes the song's length), then NetEase. Returns the lyrics found, None, or Failed when
        /// nothing was found and a source couldn't be asked (busy, unreachable, skipped for now): not a final "none".
        /// </summary>
        /// <param name="titleTolerance">a result by another artist with the exact title may be this far (seconds) from
        /// the song's length; negative = artist matches only</param>
        /// <param name="artistTolerance">how far (seconds) a result by the song's artist may be from its length</param>
        public async Task<LyricsResult> Find(SongInfo song, CancellationToken ct, double titleTolerance, double artistTolerance)
        {
            var title = SearchTitle(song);
            if (title.Length == 0 || song.Duration <= 0) return LyricsResult.None;
            var memoKey = LyricsProvider.Norm(title) + "|" + LyricsProvider.Norm(song.Artist) + "|" + (int)song.Duration + "|" + titleTolerance + "|" + artistTolerance;
            lock (gate)
            {
                LyricsResult known;
                // a copy: callers label the source ("Kugou · 원곡")
                if (memo.TryGetValue(memoKey, out known)) return known.HasSynced ? new LyricsResult { Lines = known.Lines, Source = known.Source } : known;
            }
            bool unasked = false;
            foreach (var source in new[] { kugou, netease })
            {
                if (source.Paused) { unasked = true; Log.Info(source.Name + " skipped (paused after repeated failures)"); continue; }
                try
                {
                    var found = source == kugou ? await KugouSearch(song, title, ct) : await NeteaseSearch(song, title, ct);
                    var picked = Choose(found, song, titleTolerance, artistTolerance);
                    LyricsResult result = null;
                    foreach (var c in picked.Take(2))
                    {
                        var lines = CleanLines(Lrc.Parse(source == kugou ? await KugouLyrics(c, ct) : await NeteaseLyrics(c, ct)), c);
                        if (lines.Count >= 3 && Fits(lines, c.Duration, song.Duration))
                        {
                            Log.Info("lyrics found via " + source.Name + " (" + c.Artist + " - " + c.Title + ", " + (int)c.Duration + "s): "
                                     + song.Artist + " - " + song.Title);
                            result = new LyricsResult { Lines = lines, Source = source.Name };
                            break;
                        }
                    }
                    lock (gate) source.Failures = 0;
                    if (result != null) { Remember(memoKey, new LyricsResult { Lines = result.Lines, Source = result.Source }); return result; }
                    Log.Info(source.Name + ": no match among " + found.Count + " results for \"" + title + "\" (" + picked.Count + " fit)");
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    unasked = true;
                    lock (gate)
                    {
                        if (++source.Failures >= 3) { source.SkipUntil = DateTime.UtcNow.AddMinutes(10); source.Failures = 0; }
                    }
                    Log.Write("WARN " + source.Name + " lyrics failed for " + song.Artist + " - " + song.Title + ": "
                              + (ex is OperationCanceledException ? "timeout" : ex.GetType().Name + ": " + ex.Message)
                              + (source.Paused ? " (skipped for 10 minutes)" : ""));
                }
            }
            if (unasked) return new LyricsResult { Lines = new List<LyricLine>(), Failed = true };
            Remember(memoKey, LyricsResult.None);
            return LyricsResult.None;
        }

        void Remember(string key, LyricsResult r)
        {
            lock (gate)
            {
                if (memo.Count > 200) memo.Clear();
                memo[key] = r;
            }
        }

        /// <summary>The title to search for: the original title if known, without tags and a singer's "○○ver.".</summary>
        internal static string SearchTitle(SongInfo song)
        {
            var t = !string.IsNullOrWhiteSpace(song.AltTitle) ? song.AltTitle : song.Title;
            return CoverLyrics.WithoutVersionTag(LyricsProvider.CleanTitle(LyricsProvider.WithoutFeat(t ?? ""))).Trim();
        }

        // ---- Kugou: lyrics search by keyword and length, then the chosen candidate's LRC (base64) ----------------

        async Task<List<Candidate>> KugouSearch(SongInfo song, string title, CancellationToken ct)
        {
            // Kugou finds nothing without an artist it knows ("Naisho no Pierced Earrings" for 内緒のピアス); NetEase may
            var artist = LyricsProvider.FirstArtist(song.Artist);
            if (artist.Length == 0) return new List<Candidate>();
            var d = await GetJson(KugouBase + "/search?ver=1&man=yes&client=pc&keyword=" + Uri.EscapeDataString(artist + " - " + title)
                                  + "&duration=" + ((long)(song.Duration * 1000)).ToString(CultureInfo.InvariantCulture) + "&hash=", ct);
            var list = new List<Candidate>();
            foreach (var c in Items(d, "candidates"))
                list.Add(new Candidate { Source = "Kugou", Id = LyricsProvider.Str(c, "id"), Key = LyricsProvider.Str(c, "accesskey"),
                                         Title = LyricsProvider.Str(c, "song"), Artist = LyricsProvider.Str(c, "singer"),
                                         Duration = LyricsProvider.Num(c, "duration") / 1000 });
            return list;
        }

        async Task<string> KugouLyrics(Candidate c, CancellationToken ct)
        {
            var d = await GetJson(KugouBase + "/download?ver=1&client=pc&id=" + Uri.EscapeDataString(c.Id) + "&accesskey="
                                  + Uri.EscapeDataString(c.Key) + "&fmt=lrc&charset=utf8", ct);
            var content = d != null ? LyricsProvider.Str(d, "content") : "";
            return content.Length > 0 ? Encoding.UTF8.GetString(Convert.FromBase64String(content)) : "";
        }

        // ---- NetEase: song search (with lengths), then the chosen song's LRC --------------------------------------

        async Task<List<Candidate>> NeteaseSearch(SongInfo song, string title, CancellationToken ct)
        {
            var q = (title + " " + LyricsProvider.FirstArtist(song.Artist)).Trim();
            var d = await GetJson(NeteaseBase + "/api/cloudsearch/pc?s=" + Uri.EscapeDataString(q) + "&type=1&limit=10", ct);
            object result;
            var list = new List<Candidate>();
            if (d == null || !d.TryGetValue("result", out result) || !(result is IDictionary<string, object>)) return list;
            foreach (var s in Items((IDictionary<string, object>)result, "songs"))
            {
                var artists = Items(s, "ar").Select(a => LyricsProvider.Str(a, "name")).Where(n => n.Length > 0);
                list.Add(new Candidate { Source = "NetEase", Id = LyricsProvider.Num(s, "id").ToString("0", CultureInfo.InvariantCulture),
                                         Title = LyricsProvider.Str(s, "name"), Artist = string.Join(", ", artists),
                                         Duration = LyricsProvider.Num(s, "dt") / 1000 });
            }
            return list;
        }

        async Task<string> NeteaseLyrics(Candidate c, CancellationToken ct)
        {
            var d = await GetJson(NeteaseBase + "/api/song/lyric?id=" + Uri.EscapeDataString(c.Id) + "&lv=1", ct);
            object lrc;
            if (d == null || !d.TryGetValue("lrc", out lrc) || !(lrc is IDictionary<string, object>)) return "";
            var text = LyricsProvider.Str((IDictionary<string, object>)lrc, "lyric");
            return text.Contains("纯音乐，请欣赏") ? "" : text;   // "instrumental, enjoy": no words to show
        }

        async Task<IDictionary<string, object>> GetJson(string url, CancellationToken ct)
        {
            using (var resp = await http.GetAsync(url, ct))
            {
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException(new Uri(url).Host + " " + (int)resp.StatusCode);
                return json.DeserializeObject(await resp.Content.ReadAsStringAsync()) as IDictionary<string, object>;
            }
        }

        static IEnumerable<IDictionary<string, object>> Items(IDictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || !(v is IEnumerable) || v is string) yield break;
            foreach (var o in (IEnumerable)v) { var item = o as IDictionary<string, object>; if (item != null) yield return item; }
        }

        // ---- matching (pure, tested) -------------------------------------------------------------------------------

        /// <summary>
        /// The candidates worth downloading, best first. The title must be the song's (ignoring tags and bracketed
        /// notes like "(feat. …)" or "(求婚)"); remixes and arrangements only for a song that is one. By the song's
        /// artist (or a Pear tag naming them) within artistTolerance, or by anyone with the exact title within
        /// titleTolerance (negative = not at all). Exact titles and closer lengths first.
        /// </summary>
        internal static List<Candidate> Choose(List<Candidate> found, SongInfo song, double titleTolerance, double artistTolerance)
        {
            var titles = new HashSet<string>();
            foreach (var t in new[] { song.Title, song.AltTitle })
            {
                if (string.IsNullOrWhiteSpace(t)) continue;
                var clean = LyricsProvider.CleanTitle(LyricsProvider.WithoutFeat(t));
                foreach (var x in new[] { t, clean, CoverLyrics.WithoutVersionTag(clean) }.Concat(CoverLyrics.TitleHalves(clean)))
                    titles.Add(LyricsProvider.Norm(x));
            }
            titles.Remove("");
            bool arranged = CoverLyrics.LooksArranged(song.Title) || CoverLyrics.LooksArranged(song.AltTitle);
            var ours = LyricsProvider.ArtistVariants(song.Artist);
            var names = new[] { song.Title, song.AltTitle, song.Album }.Select(LyricsProvider.Norm).Where(n => n.Length > 0).ToList();
            foreach (var tag in song.Tags ?? new List<string>())
                if (!names.Contains(LyricsProvider.Norm(tag))) ours.Add(tag.Trim().ToLowerInvariant());
            ours.Remove("");

            var ranked = new List<Tuple<Candidate, int, double>>();
            foreach (var c in found)
            {
                if (c.Duration <= 0 || (!arranged && CoverLyrics.LooksArranged(c.Title))) continue;
                bool exact = titles.Contains(LyricsProvider.Norm(c.Title)) || titles.Contains(LyricsProvider.Norm(LyricsProvider.CleanTitle(c.Title)));
                if (!exact && !titles.Contains(LyricsProvider.Norm(Bare(c.Title)))) continue;
                var theirs = LyricsProvider.ArtistVariants(c.Artist);
                bool byArtist = ours.Any(a => theirs.Any(b => LyricsProvider.JaroWinkler(a, b) > 0.9));
                double gap = Math.Abs(c.Duration - song.Duration);
                if (byArtist && gap <= artistTolerance) ranked.Add(Tuple.Create(c, exact ? 0 : 1, gap));
                else if (exact && titleTolerance >= 0 && gap <= titleTolerance) ranked.Add(Tuple.Create(c, 2, gap));
            }
            return ranked.OrderBy(r => r.Item2).ThenBy(r => r.Item3).Select(r => r.Item1).ToList();
        }

        /// <summary>The title without any bracketed part: "호랑풍류가 (시드노벨 - ′나와 호랑이님′ 주제가)" -> "호랑풍류가".</summary>
        static string Bare(string title)
        {
            var t = Regex.Replace(title ?? "", @"\s*[\(（\[【［〔][^\)）\]】］〕]*[\)）\]】］〕]", " ");
            return LyricsProvider.CleanTitle(t);
        }

        static readonly Regex Credit = new Regex(
            @"^\s*(?:作?词|作?曲|编曲|词曲|作词作曲|作詞|編曲|作詞作曲|作編曲|演唱|歌手|原唱|翻唱|制作人?|製作|监制|出品|发行|混音|混缩|缩混|母带|和声|合声|"
            + @"吉他|贝斯|鼓|弦乐|键盘|录音|录音师|配唱|人声|OP|SP|ISRC|Lyrics?|Lyricist|Music|Written by|Compos(?:er|ed by)|Arrange(?:r|d by)|"
            + @"Produc(?:er|ed by)|Vocals?|Mix(?:ed by|ing)?|Master(?:ed by|ing)?|Illust(?:ration)?|Movie|Guitar|Bass|Drums)\s*[:：]",
            RegexOptions.IgnoreCase);

        /// <summary>
        /// Drop the credits these services put among the lyrics ("作词 : …", "曲：…") and Kugou's opening
        /// "Title - Artist" line, which would otherwise scroll by as lyrics.
        /// </summary>
        internal static List<LyricLine> CleanLines(List<LyricLine> lines, Candidate c)
        {
            var title = LyricsProvider.Norm(Bare(c.Title));
            var kept = new List<LyricLine>();
            for (int i = 0; i < lines.Count; i++)
            {
                var text = lines[i].Text ?? "";
                if (Credit.IsMatch(text)) continue;
                if (i < 3 && title.Length > 0 && text.Contains(" - ") && LyricsProvider.Norm(text).Contains(title)) continue;
                kept.Add(lines[i]);
            }
            // nothing but credits and blank lines: no lyrics
            return kept.Any(l => !string.IsNullOrWhiteSpace(l.Text)) ? kept : new List<LyricLine>();
        }

        /// <summary>The last line within its own recording and this song (5s of slack), as LyricsProvider.LyricsFit.</summary>
        internal static bool Fits(List<LyricLine> lines, double own, double songDuration)
        {
            if (lines.Count == 0) return false;
            double last = lines.Max(l => l.TimeMs) / 1000.0;
            return (own <= 0 || last <= own + 5) && (songDuration <= 0 || last <= songDuration + 5);
        }

        public void Dispose() { http.Dispose(); }
    }
}
