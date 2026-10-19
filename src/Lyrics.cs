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
        /// <summary>Nothing found, but a lyrics source couldn't be asked (Kugou / NetEase failing): not cached as "none".</summary>
        public bool Unsure;
        /// <summary>The failure was LRCLIB's rate limit (429): Kugou / NetEase may stand in. Other failures (503 …)
        /// just retry LRCLIB.</summary>
        public bool RateLimited;
        /// <summary>Found on Kugou / NetEase only because LRCLIB rate-limited us (429): kept for this run but not saved
        /// to disk, so the next run asks LRCLIB again (it may have the song).</summary>
        public bool StandIn;
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
        public readonly int Status;
        public LrclibBusyException(string message, int status) : base(message) { Status = status; }
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
        /// <summary>Kugou / NetEase, asked when LRCLIB has no synced lyrics (when UseMore is on); null = not at all.</summary>
        public MoreLyrics More;
        public bool UseMore;

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
            var known = Known(song);
            if (known != null) return known;
            return await Lookup(song, ct, cacheMisses);
        }

        /// <summary>Set (for the async flow under Recheck only) while LRCLIB is asked again: no Kugou / NetEase, no YouTube Music lyrics.</summary>
        static readonly AsyncLocal<bool> lrclibOnly = new AsyncLocal<bool>();

        /// <summary>Find past the caches: asks the lyrics servers.</summary>
        async Task<LyricsResult> Lookup(SongInfo song, CancellationToken ct, bool cacheMisses)
        {
            var key = song.VideoId + "|" + song.Title;
            Log.Info((lrclibOnly.Value ? "asking LRCLIB again: " : "") + "looking up lyrics: " + song.Artist + " - " + song.Title + " [" + (string.IsNullOrEmpty(song.MediaType) ? "type?" : song.MediaType)
                     + ", " + song.VideoId + ", " + (int)song.Duration + "s]");

            // A cover's description is only needed when YouTube Music has no lyrics for the video itself, which is
            // the usual case for covers: ask for it alongside the first lookups instead of after them.
            bool coverCandidate = Ytm != null && !Ytm.Paused && !string.IsNullOrEmpty(song.VideoId) && song.Duration > 0
                                  && CoverLyrics.MayBeCover(song);
            Task<VideoDescription> description = coverCandidate && !CoverLyrics.LooksArranged(song.Title) && !CoverLyrics.LooksArranged(song.AltTitle)
                ? DescriptionOrNull(song.VideoId, ct) : null;

            // 1) YouTube Music's own synced lyrics; on any failure (relay down, rate limit) fall back to LRCLIB
            bool ytmError = false;
            if (UseYtm && Ytm != null && !string.IsNullOrEmpty(song.VideoId) && !lrclibOnly.Value)
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
            var result = await FindSynced(WithOriginalTitle(song), ct, 3, !CoverLyrics.MayBeCover(song));
            // a "not found" is only final when YouTube Music (and Kugou / NetEase) answered too; otherwise ask again next time
            if (!result.Failed && (result.HasSynced || result.Instrumental || (cacheMisses && !ytmError && !result.Unsure)))
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
                        // artist names in the title count too (as tags: they vouch for results with this title)
                        var l = await FindSynced(new SongInfo { Title = orig.Title, AltTitle = primary != orig.Title ? primary : "",
                                                                Artist = orig.Artist, Duration = orig.Duration, VideoId = id,
                                                                Tags = CoverLyrics.ArtistsInTitle(orig.Title, primary) }, ct);
                        if (l.HasSynced)
                        {
                            l.Source += " · 원곡";
                            Log.Info("lyrics found via original " + label + " on " + l.Source + ": " + song.Artist + " - " + song.Title);
                            return l;
                        }
                        if (l.Failed) return l;   // LRCLIB busy: retried later
                    }
                    Log.Info("cover: original " + label + " has no synced lyrics under that name");
                    break;   // the first usable link decides; don't wander through unrelated links
                }

                // The original's video is known but its length doesn't fit (it often has an intro or outro the
                // recording doesn't). A title guess alone would find that video's song out of sync or another song
                // of the same name, so only an artist the description names may look it up: same artist, and a
                // length within the cover's tolerance. No lyrics beats wrong lyrics.
                if (originalTooLong) return await FromSearch(song, desc, ct, true);
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
        /// <param name="byArtist">only an original artist named by the title or description, and only results by that
        /// artist within the cover's length tolerance (the linked original didn't fit)</param>
        async Task<LyricsResult> FromSearch(SongInfo song, VideoDescription desc, CancellationToken ct, bool byArtist = false)
        {
            var guess = CoverLyrics.GuessOriginal(song, desc != null ? desc.Text : null);
            string title = guess.Item1, artist = guess.Item2;
            if (title.Length == 0) { Log.Info("cover: couldn't tell the song title from \"" + song.Title + "\""); return null; }
            if (byArtist && artist.Length == 0)
            {
                Log.Info("cover: the original differs in length and no artist is named, no lyrics rather than a title guess: " + song.Title);
                return null;
            }
            Log.Info("cover: looking up the original on LRCLIB: \"" + title + "\"" + (artist.Length > 0 ? " by \"" + artist + "\"" : " (artist unknown)")
                     + (byArtist ? ", that artist only" : ""));

            // With the original artist named, another singer's lyrics only count when they are the well-known version
            // (the same timing uploaded at least 3 times): one cover of the song is no proof (Bad Apple!!: the PV's
            // lyrics, not FalKKonE's or an English cover's).
            var l = await FindSynced(new SongInfo { Title = title, Artist = artist, Duration = song.Duration, VideoId = song.VideoId + "#original" }, ct,
                                     CoverLyrics.MaxLengthDiff, !byArtist, byArtist ? CoverLyrics.MaxLengthDiff : 15, artist.Length > 0 ? 3 : 1);
            if (l.HasSynced)
            {
                l.Source += " · 원곡 검색";
                Log.Info("lyrics found via original \"" + title + "\" on " + l.Source + ": " + song.Artist + " - " + song.Title);
                return l;
            }
            return l.Failed ? l : null;   // LRCLIB busy: let the caller retry later
        }

        /// <summary>
        /// An album track whose title Pear gives only translated or romanized ("kanade tomosu sora nekobolo version")
        /// is also searched under its original title, which YouTube Music's lookup already brought
        /// ("カナデトモスソラ　ねこぼーろver."): LRCLIB mostly lists songs under their original titles.
        /// </summary>
        SongInfo WithOriginalTitle(SongInfo song)
        {
            if (song.MediaType != "AUDIO") return song;
            var track = Ytm.Known(song.VideoId);
            var original = track != null ? CoverLyrics.OriginalTitle(song.Title, track.Title) : null;
            return original != null ? song.WithAltTitle(original) : song;
        }

        /// <summary>
        /// LRCLIB, then (when it has no synced lyrics or is busy) Kugou and NetEase. Their catalogs are bigger and
        /// looser, so a title-only match there needs the exact title and length (titleMatchTolerance up to 3s, and no
        /// "several identical uploads" rule to lean on): with a wider tolerance or that rule, artist matches only.
        /// </summary>
        async Task<LyricsResult> FindSynced(SongInfo song, CancellationToken ct, double titleMatchTolerance = 3, bool titleOnly = true,
                                            double artistTolerance = 15, int titleMatchCopies = 1)
        {
            var l = await FindLrclib(song, ct, titleMatchTolerance, titleOnly, artistTolerance, titleMatchCopies);
            if (l.HasSynced || l.Instrumental || More == null || !UseMore || lrclibOnly.Value) return l;
            // Kugou / NetEase only when LRCLIB has nothing, or rate-limits us (429); when it is busy (503 …) it is
            // asked again instead, as soon as its Retry-After allows (user's choice: LRCLIB first)
            if (l.Failed && !l.RateLimited) return l;
            var m = await More.Find(song, ct, titleOnly && titleMatchCopies <= 1 && titleMatchTolerance <= 3 ? titleMatchTolerance : -1, artistTolerance);
            if (m.HasSynced) { m.StandIn = l.Failed; return m; }
            if (l.Failed) return l;   // LRCLIB rate-limited: retried later
            return m.Failed ? new LyricsResult { Lines = new List<LyricLine>(), Unsure = true } : l;
        }

        /// <param name="titleOnly">also accept a result whose artist differs if the title and length match</param>
        /// <param name="artistTolerance">how far (seconds) a result by the same artist may be from the song's length</param>
        /// <param name="titleMatchCopies">a title-only match needs this many identical uploads of its lyrics</param>
        async Task<LyricsResult> FindLrclib(SongInfo song, CancellationToken ct, double titleMatchTolerance = 3, bool titleOnly = true,
                                            double artistTolerance = 15, int titleMatchCopies = 1)
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
                // "心を刺す言葉だけ - Only Words": LRCLIB may list the song under either half (this one only as "Only Words")
                getTitles.AddRange(CoverLyrics.TitleHalves(CleanTitle(song.Title)));
                foreach (var gt in getTitles.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct().Take(4))
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
                    best = Pick(items, song, artistTolerance);
                    if (best != null) how = "search";
                }
                if (best == null)
                {
                    var alt = string.IsNullOrEmpty(song.AltTitle) ? song.Title : song.AltTitle;
                    // the last one without a "○○ver." naming the singer: other versions of the same song are listed by
                    // the bare title, and the artist / title / length checks still decide
                    foreach (var text in new[] { alt + " " + FirstArtist(song.Artist), CleanTitle(song.Title) + " " + FirstArtist(song.Artist),
                                                 CoverLyrics.WithoutVersionTag(CleanTitle(alt)) }.Distinct())
                    {
                        if (string.IsNullOrWhiteSpace(text)) continue;
                        var qText = text.Trim();
                        var items = await attempt(() => Search(new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("q", qText) }, ct));
                        seen.AddRange(items);
                        best = Pick(items, song, artistTolerance);
                        if (best != null) { how = "q=" + text.Trim(); break; }
                    }
                }

                // 3) artist written differently (e.g. "Kenshi Yonezu" vs "米津玄師"): same title and nearly the same length
                if (best == null && titleOnly)
                {
                    best = PickByTitle(seen, song, titleMatchTolerance, titleMatchCopies);
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
                var busy = ex as LrclibBusyException;
                return new LyricsResult { Lines = new List<LyricLine>(), Failed = true, RateLimited = busy != null && busy.Status == 429 };   // don't cache
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
        /// <summary>What Prefetch has for the next song, without taking it (Known does that when the song starts).</summary>
        public LyricsResult Ahead(SongInfo next)
        {
            lock (gate)
            {
                LyricsResult hit;
                if (!string.IsNullOrEmpty(next.VideoId) && prefetched.TryGetValue(next.VideoId, out hit)) return hit;
                return cache.TryGetValue(next.VideoId + "|" + next.Title, out hit) ? hit : null;
            }
        }

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

        /// <summary>When LRCLIB was last asked about a song whose lyrics came from Kugou / NetEase (by video ID, this run).</summary>
        readonly Dictionary<string, DateTime> lrclibChecked = new Dictionary<string, DateTime>();

        static string Id(SongInfo song) { return string.IsNullOrEmpty(song.VideoId) ? "|" + song.Title : song.VideoId; }

        static bool FromMore(LyricsResult r)
        {
            return r != null && r.HasSynced && r.Source != null && (r.Source.StartsWith("Kugou") || r.Source.StartsWith("NetEase"));
        }

        /// <summary>
        /// Whether LRCLIB should be asked again about lyrics found on Kugou / NetEase: a stand-in for a busy LRCLIB, or
        /// a song LRCLIB didn't have (it may have been added since), once per play but not again within a day in the
        /// same run (LRCLIB caches its answers for a day).
        /// </summary>
        public bool ShouldRecheck(SongInfo song, LyricsResult r)
        {
            if (!FromMore(r)) return false;
            if (r.StandIn) return true;
            lock (gate)
            {
                DateTime at;
                return !lrclibChecked.TryGetValue(Id(song), out at) || DateTime.UtcNow - at > TimeSpan.FromHours(24);
            }
        }

        /// <summary>
        /// Ask LRCLIB (only) again about a song whose lyrics came from Kugou / NetEase. Returns LRCLIB's lyrics (kept, on
        /// disk too), or the lyrics already known when LRCLIB has none (a stand-in then becomes final and is saved), or
        /// null when LRCLIB couldn't answer (busy): the known lyrics stay, ask again later.
        /// </summary>
        public async Task<LyricsResult> Recheck(SongInfo song, CancellationToken ct)
        {
            var known = Known(song);
            if (!FromMore(known)) return known;
            lrclibOnly.Value = true;   // flows to the calls below only, not back to the caller
            var r = await Lookup(song, ct, false);
            if (r.Failed) return null;
            lock (gate) lrclibChecked[Id(song)] = DateTime.UtcNow;
            if (r.HasSynced || r.Instrumental)
            {
                Log.Info("LRCLIB has lyrics now (" + r.Source + "), replacing " + known.Source + ": " + song.Artist + " - " + song.Title);
                return r;
            }
            if (known.StandIn)
            {
                known = new LyricsResult { Lines = known.Lines, Source = known.Source };
                Keep(song.VideoId + "|" + song.Title, song, known);
            }
            Log.Info("LRCLIB still has no lyrics, keeping " + known.Source + ": " + song.Artist + " - " + song.Title);
            return known;
        }

        /// <summary>Drop the cached result for a song (in memory and on disk) so the next Find asks again.</summary>
        public void Forget(SongInfo song)
        {
            lock (gate) { cache.Remove(song.VideoId + "|" + song.Title); prefetched.Remove(song.VideoId ?? ""); }
            if (Disk != null) Disk.Forget(song.VideoId);
        }

        /// <summary>Lyrics found on LRCLIB, Kugou or NetEase kept between runs; null = memory only.</summary>
        public LyricsDiskCache Disk;

        void Keep(string key, SongInfo song, LyricsResult r)
        {
            lock (gate)
            {
                cache[key] = r;
                if (FromMore(r) && !r.StandIn) lrclibChecked[Id(song)] = DateTime.UtcNow;   // LRCLIB just said it has none
            }
            if (Disk != null && LyricsDiskCache.Keeps(r)) Disk.Save(song, r);
        }

        static bool IsBusy(HttpResponseMessage r)
        {
            int c = (int)r.StatusCode;
            return c == 429 || c == 502 || c == 503 || c == 504;
        }

        // LRCLIB's rules (https://lrclib.net/docs, read 2026-10-20): an identified client gets ~90 requests/min per
        // IP; send requests one after another with 200-500 ms between them; on 429 or 503 wait at least Retry-After
        // (503 usually says 1s) plus up to 30% random jitter, or risk a temporary ban.
        const int Spacing = 300, PerMinute = 60, Attempts = 4, MaxRetryAfter = 30;
        readonly object pace = new object();
        readonly Queue<DateTime> recent = new Queue<DateTime>();   // request starts in the last minute
        readonly Random random = new Random();
        DateTime nextStart = DateTime.MinValue;   // pacing, and Retry-After for every request (not only the one told)
        DateTime lastBusy = DateTime.MinValue;

        /// <summary>
        /// How long to wait before trying a failed lookup again: a second right after LRCLIB said it was busy (the
        /// next request also waits for its Retry-After, so LRCLIB is asked again about as soon as it allows),
        /// otherwise (no connection, timeouts) 15 seconds.
        /// </summary>
        public TimeSpan RetryWait
        {
            get { lock (pace) return TimeSpan.FromSeconds(DateTime.UtcNow - lastBusy < TimeSpan.FromSeconds(10) ? 1 : 15); }
        }

        /// <summary>Wait for this request's turn: after the previous one plus the spacing, any Retry-After pause, and
        /// within PerMinute requests a minute (all lookups share it: the current song and the next one).</summary>
        async Task WaitTurn(CancellationToken ct)
        {
            DateTime start;
            lock (pace)
            {
                var now = DateTime.UtcNow;
                while (recent.Count > 0 && now - recent.Peek() >= TimeSpan.FromMinutes(1)) recent.Dequeue();
                start = nextStart > now ? nextStart : now;
                if (recent.Count >= PerMinute)
                {
                    var free = recent.ElementAt(recent.Count - PerMinute).AddMinutes(1);
                    if (free > start) start = free;
                }
                recent.Enqueue(start);
                nextStart = start.AddMilliseconds(Spacing);
            }
            var wait = start - DateTime.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait, ct);
        }

        /// <summary>
        /// GET, retried while LRCLIB is busy (429/502/503/504) after its Retry-After (1s if none) plus jitter, up to
        /// Attempts times; then the busy response is returned and the lookup goes on to Kugou / NetEase, and the
        /// whole lookup is tried again later. A Retry-After over MaxRetryAfter seconds isn't waited for here, but
        /// still holds back every request until it has passed.
        /// </summary>
        async Task<HttpResponseMessage> Send(string url, CancellationToken ct)
        {
            for (int i = 1; ; i++)
            {
                await WaitTurn(ct);
                var resp = await http.GetAsync(url, ct);
                if (!IsBusy(resp)) return resp;
                double seconds = 1;
                if (resp.Headers.RetryAfter != null && resp.Headers.RetryAfter.Delta.HasValue)
                    seconds = Math.Max(1, resp.Headers.RetryAfter.Delta.Value.TotalSeconds);
                else if (resp.Headers.RetryAfter != null && resp.Headers.RetryAfter.Date.HasValue)
                    seconds = Math.Max(1, (resp.Headers.RetryAfter.Date.Value - DateTimeOffset.UtcNow).TotalSeconds);
                lock (pace)
                {
                    seconds *= 1 + random.NextDouble() * 0.3;
                    var until = DateTime.UtcNow.AddSeconds(seconds);
                    if (until > nextStart) nextStart = until;
                    lastBusy = DateTime.UtcNow;
                }
                // a rate limit (429) ends the lookup at once: Kugou / NetEase stand in while LRCLIB is waited out
                bool last = i >= Attempts || seconds > MaxRetryAfter || (int)resp.StatusCode == 429;
                Log.Info("LRCLIB busy (" + (int)resp.StatusCode + "), " + (last ? "giving up for now" : "asking again") + " after "
                         + seconds.ToString("0.0", CultureInfo.InvariantCulture) + "s");
                if (last) return resp;
                resp.Dispose();
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
                if (IsBusy(resp)) throw new LrclibBusyException("LRCLIB get " + (int)resp.StatusCode, (int)resp.StatusCode);
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("LRCLIB get " + (int)resp.StatusCode);
                var d = json.DeserializeObject(await resp.Content.ReadAsStringAsync()) as IDictionary<string, object>;
                if (d == null) return null;
                if (!string.IsNullOrEmpty(Str(d, "syncedLyrics")) && !LyricsFit(d, song.Duration)) return null;
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
                if (IsBusy(resp)) throw new LrclibBusyException("LRCLIB search " + (int)resp.StatusCode, (int)resp.StatusCode);
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
        static IDictionary<string, object> Pick(List<IDictionary<string, object>> items, SongInfo song, double tolerance = 15)
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
                candidates = candidates.Where(c => Math.Abs(Num(c, "duration") - song.Duration) <= tolerance)
                                       .OrderBy(c => Math.Abs(Num(c, "duration") - song.Duration)).ToList();
            // prefer entries that actually have timestamps
            var synced = candidates.FirstOrDefault(c => !string.IsNullOrEmpty(Str(c, "syncedLyrics")) && LyricsFit(c, song.Duration));
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

        internal static string WithoutFeat(string title)
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
        /// <summary>
        /// Synced lyrics that run on past the end of their own recording, or of this song, are another version's: a
        /// "Bad Apple!!" entry listed as 232s carried the 5:19 original's lyrics (last line at 305s) and was taken for
        /// a 222s cover. Such lyrics would scroll out of step, so the entry isn't used.
        /// </summary>
        static bool LyricsFit(IDictionary<string, object> item, double songDuration)
        {
            var lines = Lrc.Parse(Str(item, "syncedLyrics"));
            if (lines.Count == 0) return true;
            double last = lines.Max(l => l.TimeMs) / 1000.0, own = Num(item, "duration");
            return (own <= 0 || last <= own + 5) && (songDuration <= 0 || last <= songDuration + 5);
        }

        /// <summary>
        /// Fallback when the artist name doesn't match: the title must be the same (ignoring case, spaces,
        /// punctuation and tags like 【PV】) and the length within the tolerance. Among several such results, the
        /// lyrics uploaded most often with the same timing win (a song's well-known version is listed many times,
        /// one singer's cover once or twice). copies: when the matches disagree (several different lyrics), how many
        /// identical uploads the winner needs; a single kind of match ("ryo" credited as "supercell") is taken as is.
        /// </summary>
        static IDictionary<string, object> PickByTitle(List<IDictionary<string, object>> items, SongInfo song, double tolerance, int copies = 1)
        {
            if (song.Duration <= 0) return null;
            var titles = new HashSet<string> { Norm(song.Title), Norm(CleanTitle(song.Title)) };
            if (!string.IsNullOrEmpty(song.AltTitle)) { titles.Add(Norm(song.AltTitle)); titles.Add(Norm(CleanTitle(song.AltTitle))); }
            titles.Remove("");
            var matches = items
                .Where(it => !string.IsNullOrEmpty(Str(it, "syncedLyrics")) && LyricsFit(it, song.Duration))
                .Where(it => titles.Contains(Norm(Str(it, "trackName"))) || titles.Contains(Norm(CleanTitle(Str(it, "trackName")))))
                .Where(it => Math.Abs(Num(it, "duration") - song.Duration) <= tolerance)
                .ToList();
            // Lyrics that sing the title are this song's: an album's lyrics can be uploaded under another track's name
            // (トンデモワンダーズ's, several times, as "チュルリラ・チュルリラ・ダッダッダ!"). Only when some do.
            var singing = matches.Where(it => titles.Any(t => t.Length >= 3 && Norm(Str(it, "syncedLyrics")).Contains(t))).ToList();
            if (singing.Count > 0) matches = singing;
            var groups = matches
                .GroupBy(LyricsTiming)
                .Select(g => new { Items = g.ToList(), Copies = g.Select(it => Str(it, "id") + "|" + Num(it, "id")).Distinct().Count() })
                .OrderByDescending(g => g.Copies)
                .ThenBy(g => g.Items.Min(it => Math.Abs(Num(it, "duration") - song.Duration)))
                .ToList();
            if (groups.Count == 0) return null;
            var best = groups[0];
            if (groups.Count > 1 && (best.Copies < copies || best.Copies == groups[1].Copies)) return null;   // no clear winner
            return best.Items.OrderBy(it => Math.Abs(Num(it, "duration") - song.Duration)).First();
        }

        /// <summary>Lyrics uploaded again with the same timing look alike: number of lines, first and last line (seconds).</summary>
        static string LyricsTiming(IDictionary<string, object> item)
        {
            var lines = Lrc.Parse(Str(item, "syncedLyrics"));
            if (lines.Count == 0) return "";
            return lines.Count + "|" + Math.Round(lines[0].TimeMs / 1000.0) + "|" + Math.Round(lines[lines.Count - 1].TimeMs / 1000.0);
        }

        internal static string Norm(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new StringBuilder();
            foreach (var ch in s.Normalize(NormalizationForm.FormKC).ToLowerInvariant())
                if (char.IsLetterOrDigit(ch)) sb.Append(ch);
            return sb.ToString();
        }

        /// <summary>"비비 (BIBI) & 윤하" -> {"비비 (bibi)", "비비", "bibi", "윤하"}</summary>
        internal static HashSet<string> ArtistVariants(string artist)
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

        internal static string FirstArtist(string artist)
        {
            var v = ArtistVariants(artist);
            return v.Count > 0 ? v.First() : "";
        }

        internal static string CleanTitleForTest(string title) { return CleanTitle(title); }

        internal static string CleanTitle(string title)
        {
            if (string.IsNullOrEmpty(title)) return "";
            // video uploads: "【歌ってみた】曲名 / covered by 誰か", "曲名【MV】", "Title (Official Video)"
            var t = Regex.Replace(title, @"【[^】]*】", " ");
            t = Regex.Replace(t, @"[\(\[][^\)\]]*(official|mv|m/v|video|audio|lyric|live|ver\.|version|feat|prod|cover|歌ってみた|踊ってみた|弾いてみた)[^\)\]]*[\)\]]", " ", RegexOptions.IgnoreCase);
            t = Regex.Replace(t, @"\s*/?\s*(covered by|cover by)\b.*$", "", RegexOptions.IgnoreCase);
            t = Regex.Replace(t, @"(?<![\p{L}\p{N}])(?:PV|MV|ＰＶ|ＭＶ)(?![\p{L}\p{N}])", " ", RegexOptions.IgnoreCase);   // "Bad Apple!! ＰＶ"
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

        internal static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }

        internal static double Num(IDictionary<string, object> d, string k)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null) return 0;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return 0; }
        }

        static bool Bool(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is bool && (bool)v;
        }

        public void Dispose() { http.Dispose(); if (Ytm != null) Ytm.Dispose(); if (More != null) More.Dispose(); }
    }
}
