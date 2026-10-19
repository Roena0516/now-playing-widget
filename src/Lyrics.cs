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
    internal sealed class LrclibBusyException : HttpRequestException
    {
        public LrclibBusyException(string message) : base(message) { }
    }

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
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PearNowPlaying/" + AppInfo.Version + " (+https://github.com/Roena0516/pear-now-playing)");
        }

        /// <summary>YouTube Music lyrics (tried first when UseYtm is on); null = LRCLIB only.</summary>
        public YtmLyrics Ytm;
        public bool UseYtm;

        public Task<LyricsResult> Find(SongInfo song, CancellationToken ct) { return Find(song, ct, true); }

        /// <param name="cacheMisses">false for a look-ahead: a "not found" from the queue's sparser song info
        /// shouldn't stop the song from being looked up again with Pear's full info when it starts</param>
        /// <summary>
        /// A result known without asking anyone: this run's cache, the one fetched ahead, or the disk cache. Null when
        /// a lookup is needed. Lets a song change swap the lyrics in place instead of closing the card first.
        /// </summary>
        public LyricsResult Known(SongInfo song)
        {
            var key = song.VideoId + "|" + song.Title;
            lock (gate)
            {
                LyricsResult hit;
                if (cache.TryGetValue(key, out hit)) return hit;
                // fetched ahead while the previous song played (the queue's title can differ slightly, so by video ID)
                if (!string.IsNullOrEmpty(song.VideoId) && prefetched.TryGetValue(song.VideoId, out hit))
                {
                    prefetched.Remove(song.VideoId);
                    cache[key] = hit;
                    Log.Info("lyrics ready (fetched ahead): " + song.Artist + " - " + song.Title);
                    return hit;
                }
            }
            // found on LRCLIB in an earlier run
            var stored = Disk != null ? Disk.Load(song.VideoId) : null;
            if (stored != null)
            {
                lock (gate) cache[key] = stored;
                Log.Info("lyrics from the disk cache (" + stored.Source + "): " + song.Artist + " - " + song.Title);
            }
            return stored;
        }

        async Task<LyricsResult> Find(SongInfo song, CancellationToken ct, bool cacheMisses)
        {
            var key = song.VideoId + "|" + song.Title;
            var known = Known(song);
            if (known != null) return known;

            Log.Info("looking up lyrics: " + song.Artist + " - " + song.Title + " [" + (string.IsNullOrEmpty(song.MediaType) ? "type?" : song.MediaType)
                     + ", " + song.VideoId + ", " + (int)song.Duration + "s]");

            // A cover's description is only needed when YouTube Music has no lyrics for the video itself, which is
            // the usual case for covers: ask for it alongside the first lookups instead of after them.
            bool coverCandidate = Ytm != null && !Ytm.Paused && !string.IsNullOrEmpty(song.VideoId) && song.Duration > 0
                                  && CoverLyrics.MayBeCover(song);
            Task<VideoDescription> description = coverCandidate && !CoverLyrics.LooksArranged(song.Title) && !CoverLyrics.LooksArranged(song.AltTitle)
                ? DescriptionOrNull(song.VideoId, ct) : null;

            // 1) YouTube Music's own synced lyrics; on any failure (relay down, rate limit) fall back to LRCLIB
            bool ytmError = false;
            if (UseYtm && Ytm != null && !string.IsNullOrEmpty(song.VideoId))
            {
                if (Ytm.Paused) { ytmError = true; Log.Info("YouTube Music skipped (relay paused after repeated failures) -> LRCLIB"); }
                else
                {
                    try
                    {
                        var info = await Ytm.Lookup(song.VideoId, ct);
                        var y = info.Lyrics;
                        if (y != null && y.HasSynced)
                        {
                            Log.Info("lyrics found via YouTube Music: " + song.Artist + " - " + song.Title + " (" + (int)song.Duration + "s)");
                            lock (gate) cache[key] = y;
                            return y;
                        }
                        // a music video: YouTube Music has timed lyrics only on the official audio track
                        var audio = await AudioTrackLyrics(info, ct);
                        if (audio != null)
                        {
                            audio.Source = "YouTube Music · 공식 음원";
                            Log.Info("lyrics found via the official audio track on YouTube Music: " + song.Artist + " - " + song.Title);
                            lock (gate) cache[key] = audio;
                            return audio;
                        }
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (Exception ex)
                    {
                        ytmError = true;
                        Log.Write("WARN YouTube Music lyrics failed for " + song.Artist + " - " + song.Title + ": "
                                  + (ex is OperationCanceledException ? "timeout" : ex.GetType().Name + ": " + ex.Message) + " -> LRCLIB");
                    }
                }
            }

            // 2) covers: the original song linked in the description, if the music wasn't changed
            // (uses YouTube only for the description and the original's title/length, so it runs even with ytmLyrics=false)
            if (coverCandidate && !Ytm.Paused)
            {
                var original = await FromOriginal(song, description, ct);
                if (original != null && original.Failed) return original;   // LRCLIB busy: retried later, not cached
                if (original != null)
                {
                    Keep(key, song, original);
                    return original;
                }
            }

            // 3) LRCLIB
            // a cover's own title can only match LRCLIB by title (the uploader isn't the original artist), which picks
            // songs that merely share the name: covers take artist matches only
            var result = await FindLrclib(song, ct, 3, !CoverLyrics.MayBeCover(song));
            // a "not found" is only final when YouTube Music answered too; otherwise ask again next time
            if (!result.Failed && (result.HasSynced || result.Instrumental || (cacheMisses && !ytmError)))
                Keep(key, song, result);
            return result;
        }

        /// <summary>
        /// Synced lyrics of the original song for a cover: follow the YouTube links in the cover's description, take
        /// the first linked video whose length is within a few seconds of the cover, and use its YouTube Music
        /// lyrics (or LRCLIB with the original's title/artist). Covers that say they are remixes/arrangements and
        /// candidates whose length differs are skipped, since the timing would drift. Null = not usable.
        /// </summary>
        async Task<LyricsResult> FromOriginal(SongInfo song, Task<VideoDescription> description, CancellationToken ct)
        {
            if (CoverLyrics.LooksArranged(song.Title) || CoverLyrics.LooksArranged(song.AltTitle))
            {
                Log.Info("cover: title says arranged/remixed, original's lyrics not used: " + song.Title);
                return null;
            }
            try
            {
                var desc = description != null ? await description : null;
                bool originalTooLong = false;
                HashSet<string> hinted;
                var ids = CoverLyrics.OriginalCandidates(desc, song.VideoId, out hinted);
                if (ids.Count == 0) Log.Info("cover: no YouTube links in the description of " + song.VideoId);
                foreach (var id in ids)
                {
                    var orig = await Ytm.Lookup(id, ct, UseYtm);
                    var label = id + " (" + orig.Artist + " - " + orig.Title + ", " + (int)orig.Duration + "s)";
                    if (orig.Duration <= 0) { Log.Info("cover: original candidate " + id + " has no known length, skipped"); continue; }
                    if (CoverLyrics.LooksArranged(orig.Title)) { Log.Info("cover: candidate " + label + " is an arrangement, skipped"); continue; }
                    // links without an "原曲 / original" label are often the singer's other videos: the title must fit
                    if (!hinted.Contains(id) && !CoverLyrics.TitleMatchesCover(song, orig))
                    {
                        Log.Info("cover: candidate " + label + " is a different song, skipped");
                        continue;
                    }
                    double diff = Math.Abs(orig.Duration - song.Duration);
                    if (diff > CoverLyrics.MaxLengthDiff)
                    {
                        Log.Info("cover: candidate " + label + " differs from the cover by " + (int)diff + "s, skipped");
                        originalTooLong = true;
                        continue;
                    }
                    if (orig.Lyrics != null && orig.Lyrics.HasSynced)
                    {
                        orig.Lyrics.Source = "YouTube Music · 원곡";
                        Log.Info("lyrics found via original " + label + " on YouTube Music: " + song.Artist + " - " + song.Title);
                        return orig.Lyrics;
                    }
                    if (UseYtm)
                    {
                        // the link is usually the original's music video; its official audio track has the timed lyrics
                        // the cover may call it differently ("帝国少女" for "Imperial Girl")
                        var coverName = CoverLyrics.GuessOriginal(song, desc != null ? desc.Text : null).Item1;
                        var audio = await AudioTrackLyrics(orig, ct, coverName);
                        if (audio != null)
                        {
                            audio.Source = "YouTube Music · 원곡";
                            Log.Info("lyrics found via original " + label + "'s official audio on YouTube Music: " + song.Artist + " - " + song.Title);
                            return audio;
                        }
                    }
                    if (!string.IsNullOrEmpty(orig.Title))
                    {
                        // "ビノミ - Binomi": also try the title without the romanized/translated half
                        var primary = CoverLyrics.PrimaryTitle(orig.Title, orig.Artist);
                        var l = await FindLrclib(new SongInfo { Title = orig.Title, AltTitle = primary != orig.Title ? primary : "",
                                                                Artist = orig.Artist, Duration = orig.Duration, VideoId = id }, ct);
                        if (l.HasSynced)
                        {
                            l.Source = "LRCLIB · 원곡";
                            Log.Info("lyrics found via original " + label + " on LRCLIB: " + song.Artist + " - " + song.Title);
                            return l;
                        }
                        if (l.Failed) return l;   // LRCLIB busy: retried later
                    }
                    Log.Info("cover: original " + label + " has no synced lyrics on LRCLIB under that name");
                    break;   // the first usable link decides; don't wander through unrelated links
                }

                // The original is known but its length doesn't fit: guessing from the title would only find that
                // original again (out of sync) or another song with the same name. No lyrics beats wrong lyrics.
                if (originalTooLong)
                {
                    Log.Info("cover: the original differs in length, no lyrics rather than a title guess: " + song.Title);
                    return null;
                }
                // no usable link: work out the song from the title / description and look it up on LRCLIB
                return await FromSearch(song, desc, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Write("WARN cover -> original lookup failed for " + song.Title + ": "
                          + (ex is OperationCanceledException ? "timeout" : ex.GetType().Name + ": " + ex.Message));
            }
            return null;
        }

        /// <summary>
        /// No usable link: read the song title (and original artist, if given) from the cover's title or description
        /// and look the original up on LRCLIB. (YouTube Music's own search doesn't list songs without signing in,
        /// so it can't be used for this.) The original must be within a few seconds of the cover's length.
        /// </summary>
        async Task<LyricsResult> FromSearch(SongInfo song, VideoDescription desc, CancellationToken ct)
        {
            var guess = CoverLyrics.GuessOriginal(song, desc != null ? desc.Text : null);
            string title = guess.Item1, artist = guess.Item2;
            if (title.Length == 0) { Log.Info("cover: couldn't tell the song title from \"" + song.Title + "\""); return null; }
            Log.Info("cover: looking up the original on LRCLIB: \"" + title + "\"" + (artist.Length > 0 ? " by \"" + artist + "\"" : " (artist unknown)"));

            var l = await FindLrclib(new SongInfo { Title = title, Artist = artist, Duration = song.Duration, VideoId = song.VideoId + "#original" }, ct,
                                     CoverLyrics.MaxLengthDiff);
            if (l.HasSynced)
            {
                l.Source = "LRCLIB · 원곡 검색";
                Log.Info("lyrics found via original \"" + title + "\" on LRCLIB: " + song.Artist + " - " + song.Title);
                return l;
            }
            return l.Failed ? l : null;   // LRCLIB busy: let the caller retry later
        }

        /// <param name="titleOnly">also accept a result whose artist differs if the title and length match</param>
        async Task<LyricsResult> FindLrclib(SongInfo song, CancellationToken ct, double titleMatchTolerance = 3, bool titleOnly = true)
        {
            LyricsResult result = LyricsResult.None;
            string how = "not found";
            try
            {
                // A request that fails for a reason other than "server busy" (bad response, 500 …) doesn't end
                // the lookup: the next way of searching is tried, and the error only counts if nothing turns up.
                // Busy answers and timeouts end it, since the following requests would hit the same wall.
                Exception lastError = null;
                Func<Func<Task<List<IDictionary<string, object>>>>, Task<List<IDictionary<string, object>>>> attempt = async call =>
                {
                    try { return await call(); }
                    catch (OperationCanceledException) { throw; }
                    catch (LrclibBusyException) { throw; }
                    catch (Exception ex) { lastError = ex; Log.Write("INFO LRCLIB request failed (" + ex.Message + "), trying the next search"); return new List<IDictionary<string, object>>(); }
                };

                // 1) exact signature lookup (artist + title + album + duration): one row, usually fast
                IDictionary<string, object> best = null;
                // also under the alternative / cleaned-up title ("ビノミ - Binomi" -> "ビノミ"): exact lookups are cheap
                var getTitles = new List<string> { song.Title };
                if (!string.IsNullOrEmpty(song.AltTitle)) getTitles.Add(song.AltTitle);
                getTitles.Add(CleanTitle(song.Title));
                foreach (var gt in getTitles.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct().Take(3))
                {
                    try { best = await Get(new SongInfo { Title = gt, Artist = song.Artist, Album = song.Album, Duration = song.Duration }, ct); }
                    catch (OperationCanceledException) { throw; }
                    catch (LrclibBusyException) { throw; }
                    catch (Exception ex) { lastError = ex; Log.Write("INFO LRCLIB get failed (" + ex.Message + "), trying search"); }
                    if (best != null) { how = gt == song.Title ? "get" : "get \"" + gt + "\""; break; }
                }

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
                    var items = await attempt(() => Search(q, ct));
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
                        var qText = text.Trim();
                        var items = await attempt(() => Search(new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("q", qText) }, ct));
                        seen.AddRange(items);
                        best = Pick(items, song);
                        if (best != null) { how = "q=" + text.Trim(); break; }
                    }
                }

                // 3) artist written differently (e.g. "Kenshi Yonezu" vs "米津玄師"): same title and nearly the same length
                if (best == null && titleOnly)
                {
                    best = PickByTitle(seen, song, titleMatchTolerance);
                    if (best != null) how = "title match (" + Str(best, "artistName") + ")";
                }
                if (best == null && lastError != null) throw lastError;

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
            Log.Info("lyrics " + (result.HasSynced ? "found via LRCLIB " + how : result.Instrumental ? "instrumental" : "not found")
                     + ": " + song.Artist + " - " + song.Title + " (" + (int)song.Duration + "s)");
            return result;
        }

        readonly Dictionary<string, LyricsResult> prefetched = new Dictionary<string, LyricsResult>();

        /// <summary>
        /// Look the next song up ahead of time. Only a found result is kept for it; if nothing turns up, the song
        /// is looked up again normally when it starts (with Pear's fuller song info).
        /// </summary>
        /// <returns>false when the lookup failed (lyrics server busy or unreachable) and is worth trying again</returns>
        public async Task<bool> Prefetch(SongInfo next, CancellationToken ct)
        {
            lock (gate)
            {
                if (cache.ContainsKey(next.VideoId + "|" + next.Title) || prefetched.ContainsKey(next.VideoId)) return true;
            }
            Log.Info("fetching lyrics ahead for the next song: " + next.Artist + " - " + next.Title);
            var r = await Find(next, ct, false);
            if (r.HasSynced || r.Instrumental)
                lock (gate)
                {
                    if (prefetched.Count > 20) prefetched.Clear();
                    prefetched[next.VideoId] = r;
                }
            return !r.Failed;
        }

        /// <summary>The video's description, or null when it can't be read (logged). Only cancellation is thrown.</summary>
        async Task<VideoDescription> DescriptionOrNull(string videoId, CancellationToken ct)
        {
            try { return await Ytm.Description(videoId, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Write("INFO cover: description unavailable (" + (ex is OperationCanceledException ? "timeout" : ex.Message) + "), using the title only");
                return null;
            }
        }

        /// <summary>
        /// For a music video / upload: find the official audio track (artist page -> single/album) and get its
        /// YouTube Music lyrics. Null when there is none or it has no timed lyrics. Failures are logged, not thrown.
        /// </summary>
        async Task<LyricsResult> AudioTrackLyrics(TrackInfo video, CancellationToken ct, params string[] otherNames)
        {
            if (video == null || video.VideoType == "MUSIC_VIDEO_TYPE_ATV") return null;
            try
            {
                var audioId = await Ytm.FindAudioTrack(video, ct, otherNames);
                if (string.IsNullOrEmpty(audioId) || audioId == video.VideoId) return null;
                var audio = await Ytm.Lookup(audioId, ct);
                return audio.Lyrics != null && audio.Lyrics.HasSynced ? audio.Lyrics : null;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Write("INFO official audio lookup failed for " + video.VideoId + ": " + (ex is OperationCanceledException ? "timeout" : ex.Message));
                return null;
            }
        }

        /// <summary>Drop the cached result for a song (in memory and on disk) so the next Find asks again.</summary>
        public void Forget(SongInfo song)
        {
            lock (gate) { cache.Remove(song.VideoId + "|" + song.Title); prefetched.Remove(song.VideoId ?? ""); }
            if (Disk != null) Disk.Forget(song.VideoId);
        }

        /// <summary>Lyrics found on LRCLIB kept between runs; null = memory only.</summary>
        public LyricsDiskCache Disk;

        void Keep(string key, SongInfo song, LyricsResult r)
        {
            lock (gate) cache[key] = r;
            if (Disk != null && LyricsDiskCache.Keeps(r)) Disk.Save(song, r);
        }

        /// <summary>
        /// GET with one quick retry when LRCLIB is busy (429/502/503/504). It is a free, volunteer-run
        /// service whose search endpoint answers 503 fairly often under load; keep the request count low.
        /// </summary>
        static bool IsBusy(HttpResponseMessage r)
        {
            int c = (int)r.StatusCode;
            return c == 429 || c == 502 || c == 503 || c == 504;
        }

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
                if (IsBusy(resp)) throw new LrclibBusyException("LRCLIB get " + (int)resp.StatusCode);
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
                if (IsBusy(resp)) throw new LrclibBusyException("LRCLIB search " + (int)resp.StatusCode);
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("LRCLIB search " + (int)resp.StatusCode);
                var body = await resp.Content.ReadAsStringAsync();
                var arr = json.DeserializeObject(body) as IEnumerable;
                var list = new List<IDictionary<string, object>>();
                if (arr != null) foreach (var o in arr) { var d = o as IDictionary<string, object>; if (d != null) list.Add(d); }
                return list;
            }
        }

        /// <summary>
        /// The result by the same artist and of about the same length. Pear's tags count as artist names too (they
        /// often hold the artist's other spellings), but a tag only vouches for the artist: tags that are the song or
        /// album name are left out, and a result matched through a tag must also have the song's title. Otherwise
        /// "LAMIA" by BlackY (tagged "LAMIA") took a song by the rapper Lamia.
        /// </summary>
        static IDictionary<string, object> Pick(List<IDictionary<string, object>> items, SongInfo song)
        {
            var ours = ArtistVariants(song.Artist);
            var names = new[] { song.Title, song.AltTitle, CleanTitle(song.Title), CleanTitle(song.AltTitle), song.Album }
                .Select(Norm).Where(n => n.Length > 0).ToList();
            var tags = (song.Tags ?? new List<string>()).Select(t => t.ToLowerInvariant())
                .Where(t => !ours.Contains(t) && !names.Contains(Norm(t))).ToList();
            var candidates = new List<IDictionary<string, object>>();
            foreach (var it in items)
            {
                var theirs = ArtistVariants(Str(it, "artistName"));
                double ratio = 0;
                foreach (var a in ours) foreach (var b in theirs) ratio = Math.Max(ratio, JaroWinkler(a, b));
                if (ratio > 0.9) { candidates.Add(it); continue; }
                if (tags.Count == 0 || !TitleFits(Str(it, "trackName"), song)) continue;
                foreach (var a in tags) foreach (var b in theirs) ratio = Math.Max(ratio, JaroWinkler(a, b));
                if (ratio > 0.9) candidates.Add(it);
            }
            if (song.Duration > 0)
                candidates = candidates.Where(c => Math.Abs(Num(c, "duration") - song.Duration) <= 15)
                                       .OrderBy(c => Math.Abs(Num(c, "duration") - song.Duration)).ToList();
            // prefer entries that actually have timestamps
            var synced = candidates.FirstOrDefault(c => !string.IsNullOrEmpty(Str(c, "syncedLyrics")));
            if (synced != null) return synced;
            // "instrumental" hides the lyrics, so it has to be about this very version: other remixes of the song
            // fall within the length tolerance too (PUPA (Endorfin. Remix) took the uma remix's mark). And if an entry
            // of this version has words, the mark is someone's mistake.
            var same = candidates.Where(c => SameVersion(Str(c, "trackName"), song)).ToList();
            if (same.Any(c => !Bool(c, "instrumental") && !string.IsNullOrWhiteSpace(Str(c, "plainLyrics")))) return null;
            return same.FirstOrDefault(c => Bool(c, "instrumental"));
        }

        /// <summary>
        /// The same title once featured artists are left out, so remix and version tags must agree:
        /// "PUPA (feat. Endorfin.) [Endorfin. Remix]" is "PUPA (Endorfin. Remix)", but "PUPA (uma Remix)" and "PUPA" are not.
        /// </summary>
        internal static bool SameVersion(string trackName, SongInfo song)
        {
            var t = Norm(WithoutFeat(trackName));
            return t.Length > 0 && new[] { song.Title, song.AltTitle }.Any(x => Norm(WithoutFeat(x)) == t);
        }

        static string WithoutFeat(string title)
        {
            if (string.IsNullOrEmpty(title)) return "";
            var t = Regex.Replace(title, @"[\(\[（][^\)\]）]*\b(feat|ft|with)\b[^\)\]）]*[\)\]）]", " ", RegexOptions.IgnoreCase);
            return Regex.Replace(t, @"\s+(feat\.?|ft\.?)\s.*$", "", RegexOptions.IgnoreCase);
        }

        /// <summary>A result's track name is this song (its title, alternative title or cleaned-up title).</summary>
        static bool TitleFits(string trackName, SongInfo song)
        {
            return new[] { song.Title, song.AltTitle, CleanTitle(song.Title) }.Where(t => !string.IsNullOrWhiteSpace(t))
                .Any(t => CoverLyrics.SameTitle(trackName, t));
        }

        /// <summary>
        /// Fallback when the artist name doesn't match: the title must be the same (ignoring case, spaces
        /// and punctuation) and the length within 3 seconds, which together are very unlikely to collide.
        /// </summary>
        static IDictionary<string, object> PickByTitle(List<IDictionary<string, object>> items, SongInfo song, double tolerance)
        {
            if (song.Duration <= 0) return null;
            var titles = new HashSet<string> { Norm(song.Title), Norm(CleanTitle(song.Title)) };
            if (!string.IsNullOrEmpty(song.AltTitle)) { titles.Add(Norm(song.AltTitle)); titles.Add(Norm(CleanTitle(song.AltTitle))); }
            titles.Remove("");
            return items
                .Where(it => !string.IsNullOrEmpty(Str(it, "syncedLyrics")))
                .Where(it => titles.Contains(Norm(Str(it, "trackName"))))
                .Where(it => Math.Abs(Num(it, "duration") - song.Duration) <= tolerance)
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

        public void Dispose() { http.Dispose(); if (Ytm != null) Ytm.Dispose(); }
    }
}
