using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    /// <summary>
    /// YouTube Music's own time-synced lyrics, fetched the same way as Pear Desktop's "YTMusic" lyrics
    /// provider (src/plugins/synced-lyrics/providers/YTMusic.ts) and the macOS port (macos/Sources/YTMusicProvider.swift):
    ///   1. /youtubei/v1/next for the video -> the lyrics tab's browseId
    ///   2. /browse for that browseId as the YouTube Music mobile client (26 / 7.01.05) through Pear's relay
    ///      (ytmbrowseproxy.zvz.be). Anonymous direct browse returns no lyrics, which is why Pear uses the relay.
    ///      In practice timed lines come back for official audio tracks; MVs and uploads get "not available".
    /// No Google account cookies or Pear tokens are sent. The relay is a third-party service (Pear's code
    /// notes a shared limit of about 2 requests/second), so after repeated failures it is skipped for a
    /// while and lookups go straight to LRCLIB.
    /// </summary>
    internal sealed class TrackInfo
    {
        public string VideoId = "", Title = "", Artist = "";
        /// <summary>YouTube Music artist page of the video's artist (UC…), when the response links one.</summary>
        public string ArtistId = "";
        /// <summary>MUSIC_VIDEO_TYPE_ATV (official audio), _OMV (official video), _UGC …</summary>
        public string VideoType = "";
        public double Duration;
        public LyricsResult Lyrics;
    }

    internal sealed class VideoDescription
    {
        public string Text = "";
        public List<string> LinkedIds = new List<string>();
    }

    internal sealed class YtmLyrics : IDisposable
    {
        public const string DefaultProxy = "https://ytmbrowseproxy.zvz.be/";
        /// <summary>WEB_REMIX versions are dated builds ("1.YYYYMMDD.01.00"); a recent date is what the web app sends.</summary>
        static string WebClientVersion { get { return "1." + DateTime.UtcNow.AddDays(-2).ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".01.00"; } }

        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly object gate = new object();

        public string MusicBase = "https://music.youtube.com/";
        public string ProxyBase = DefaultProxy;

        int consecutiveFailures;
        DateTime skipUntil = DateTime.MinValue;
        const int FailuresBeforeSkip = 3;
        static readonly TimeSpan SkipFor = TimeSpan.FromMinutes(10);

        public YtmLyrics()
        {
            // redirects are followed by hand: a 301/302 would otherwise turn the POST into a GET
            http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PearNowPlaying/1.5.0");
            http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        }

        /// <summary>True while the relay is being skipped after repeated failures.</summary>
        public bool Paused { get { lock (gate) return DateTime.UtcNow < skipUntil; } }

        public void ResetPause() { lock (gate) { skipUntil = DateTime.MinValue; consecutiveFailures = 0; } }

        /// <summary>
        /// Synced lyrics for the video, or null when YouTube Music has none (no lyrics tab, or only
        /// plain text). Throws when the servers can't be reached or answer with an error.
        /// </summary>
        public async Task<LyricsResult> Find(string videoId, CancellationToken ct)
        {
            return (await Lookup(videoId, ct)).Lyrics;
        }

        /// <summary>Lyrics plus the track's title/artist/length as YouTube Music lists it (for cover -> original).</summary>
        // Answers from YouTube for this session, so retries (LRCLIB busy) and the next lookups of the same
        // originals don't ask again. Failed requests are not remembered.
        readonly Dictionary<string, TrackInfo> lookups = new Dictionary<string, TrackInfo>();
        readonly Dictionary<string, string> audioTracks = new Dictionary<string, string>();
        readonly Dictionary<string, VideoDescription> descriptions = new Dictionary<string, VideoDescription>();

        static T Remember<T>(Dictionary<string, T> memo, string key, T value)
        {
            lock (memo) { if (memo.Count > 300) memo.Clear(); memo[key] = value; }
            return value;
        }

        static bool Recall<T>(Dictionary<string, T> memo, string key, out T value)
        {
            lock (memo) return memo.TryGetValue(key, out value);
        }

        static TrackInfo Copy(TrackInfo t)
        {
            return new TrackInfo
            {
                VideoId = t.VideoId, Title = t.Title, Artist = t.Artist, ArtistId = t.ArtistId, VideoType = t.VideoType, Duration = t.Duration,
                Lyrics = t.Lyrics == null ? null : new LyricsResult { Lines = t.Lyrics.Lines, Instrumental = t.Lyrics.Instrumental, Source = t.Lyrics.Source },
            };
        }

        public async Task<TrackInfo> Lookup(string videoId, CancellationToken ct, bool withLyrics = true)
        {
            TrackInfo known;
            if (Recall(lookups, videoId + (withLyrics ? "|L" : "|M"), out known)) return Copy(known);
            if (!withLyrics && Recall(lookups, videoId + "|L", out known)) return Copy(known);
            try
            {
                var info = new TrackInfo { VideoId = videoId };
                info.Lyrics = await FindCore(videoId, ct, info, withLyrics);
                lock (gate) consecutiveFailures = 0;
                Remember(lookups, videoId + (withLyrics ? "|L" : "|M"), info);
                return Copy(info);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch
            {
                lock (gate)
                {
                    if (++consecutiveFailures >= FailuresBeforeSkip)
                    {
                        skipUntil = DateTime.UtcNow + SkipFor;
                        consecutiveFailures = 0;
                        Log.Write("WARN YouTube Music lyrics failed " + FailuresBeforeSkip + " times in a row; using LRCLIB only for " + SkipFor.TotalMinutes + " minutes");
                    }
                }
                throw;
            }
        }

        async Task<LyricsResult> FindCore(string videoId, CancellationToken ct, TrackInfo info, bool withLyrics = true)
        {
            // 1) watch-next page of the video: find the lyrics tab
            var next = await Post(MusicBase.TrimEnd('/') + "/youtubei/v1/next?prettyPrint=false", new Dictionary<string, object>
            {
                { "videoId", videoId },
                { "context", new Dictionary<string, object> { { "client", new Dictionary<string, object> {
                    { "clientName", "WEB_REMIX" }, { "clientVersion", WebClientVersion } } } } },
            }, ct, "next");
            ReadQueueEntry(next, videoId, info);
            if (!withLyrics) return null;   // only the title/artist/length were wanted
            var browseId = LyricsBrowseId(next, 0);
            if (string.IsNullOrEmpty(browseId))
            {
                Log.Info("YouTube Music: no lyrics tab for video " + videoId + " -> LRCLIB");   // user uploads, covers, MVs …
                return null;
            }

            // 2) the lyrics page as the mobile client (same request body as Pear)
            var body = new Dictionary<string, object>
            {
                { "browseId", browseId },
                { "context", new Dictionary<string, object> { { "client", new Dictionary<string, object> {
                    { "clientName", "26" }, { "clientVersion", "7.01.05" } } } } },
            };
            // Asking music.youtube.com directly (anonymously) has always answered "Lyrics not available at this time."
            // in practice, so go straight to Pear's relay, which does return timed lines for official audio tracks.
            var relayResp = await Post(ProxyBase.TrimEnd('/') + "/browse?prettyPrint=false", body, ct, "relay browse");
            var relayed = Parse(relayResp);
            if (relayed == null) Log.Info("YouTube Music relay browse " + videoId + ": no timed lines (" + Describe(relayResp) + ")");
            return relayed;
        }

        /// <summary>Short summary of a /browse answer for the log: what kind of lyrics (if any) it carried.</summary>
        static string Describe(object resp)
        {
            var contents = Path(resp, "contents");
            if (contents == null)
            {
                var d = resp as IDictionary<string, object>;
                return "no contents" + (d != null ? " [" + string.Join(",", d.Keys.Take(6)) + "]" : "");
            }
            var timed = Find(contents, "timedLyricsData", 0) as IEnumerable;
            if (timed != null)
            {
                int n = 0, cued = 0;
                foreach (var item in timed) { n++; if (Path(item, "cueRange") != null) cued++; }
                return "timedLyricsData " + n + " lines, " + cued + " with times";
            }
            var shelf = Find(contents, "musicDescriptionShelfRenderer", 0);
            if (shelf != null) return "plain lyrics only";
            var model = Find(contents, "musicMessageModel", 0);
            if (model != null) return "message: " + (Path(model, "text") as string ?? "?");
            var msg = Runs(Path(Find(contents, "messageRenderer", 0), "text"));
            if (!string.IsNullOrEmpty(msg)) return "message: " + msg;
            var cd = contents as IDictionary<string, object>;
            return "contents [" + (cd != null ? string.Join(",", cd.Keys.Take(6)) : "?") + "]";
        }

        /// <summary>Title, artist and length of the video from the "up next" queue entry YouTube Music returns for it.</summary>
        static void ReadQueueEntry(object next, string videoId, TrackInfo info)
        {
            var r = FindWhere(next, "playlistPanelVideoRenderer", v => Path(v, "videoId") as string == videoId, 0);
            if (r == null) return;
            info.Title = Runs(Path(r, "title"));
            var byline = Path(r, "shortBylineText") ?? Path(r, "longBylineText");
            var runs = Path(byline, "runs") as IEnumerable;
            if (runs != null) foreach (var run in runs) { var t = Path(run, "text") as string; if (!string.IsNullOrWhiteSpace(t)) { info.Artist = t.Trim(); break; } }
            info.Duration = ParseClock(Runs(Path(r, "lengthText")));
            info.VideoType = Find(r, "musicVideoType", 0) as string ?? "";
            var artist = FindWhere(next, "browseEndpoint", v =>
                Path(v, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as string == "MUSIC_PAGE_TYPE_ARTIST", 0);
            info.ArtistId = Path(artist, "browseId") as string ?? "";
        }

        // ---- official audio track for a music video (MV -> artist page -> single/album -> track) -------------

        /// <summary>
        /// YouTube Music only returns timed lyrics for official audio tracks, not for music videos, and without
        /// signing in it doesn't link a video to its audio track. So: open the artist's page, take the singles/albums
        /// named like the song, and pick the track with the same title and (nearly) the same length.
        /// Returns the audio track's video ID, or null.
        /// </summary>
        /// <param name="otherNames">more names the song may go by (e.g. the one a cover's title uses)</param>
        public async Task<string> FindAudioTrack(TrackInfo video, CancellationToken ct, params string[] otherNames)
        {
            if (string.IsNullOrEmpty(video.ArtistId) || string.IsNullOrEmpty(video.Title) || video.Duration <= 0) return null;
            var key = video.VideoId + "|" + string.Join("|", otherNames ?? new string[0]);
            string known;
            if (Recall(audioTracks, key, out known)) return known;
            return Remember(audioTracks, key, await FindAudioTrackCore(video, otherNames, ct));
        }

        async Task<string> FindAudioTrackCore(TrackInfo video, string[] otherNames, CancellationToken ct)
        {
            // the song's names: no 【tags】 / artist part / "covered by …"; Japanese and English halves both tried
            // ("サイエンス - Science" may be released as either)
            var names = CoverLyrics.TitleNames(video.Title, video.Artist, otherNames);
            if (names.Count == 0) return null;
            var title = string.Join(" / ", names);
            Func<string, bool> named = t => names.Any(n => CoverLyrics.SameTitle(t, n) || CoverLyrics.SameTitle(CoverLyrics.PrimaryTitle(t), n));
            var browseUrl = MusicBase.TrimEnd('/') + "/youtubei/v1/browse?prettyPrint=false";
            object artistPage;
            if (!Recall(artistPages, video.ArtistId, out artistPage))
                artistPage = Remember(artistPages, video.ArtistId, await Post(browseUrl, BrowseBody(video.ArtistId), ct, "artist page"));
            var releases = new List<Tuple<string, string>>();   // (browseId, title)
            CollectReleases(artistPage, releases, 0);
            Func<List<string>> match = () => releases
                .Where(r => !CoverLyrics.LooksArranged(r.Item2))
                .Where(r => named(r.Item2))
                .Select(r => r.Item1).Distinct().Take(2).ToList();
            var matching = match();

            // The artist page only shows the latest releases; "show all" (full singles / albums lists) has the rest.
            if (matching.Count == 0)
            {
                List<Tuple<string, string>> all;
                if (!Recall(fullDiscographies, video.ArtistId, out all))
                {
                    all = new List<Tuple<string, string>>();
                    var more = new List<Tuple<string, string>>();
                    CollectDiscographyLinks(artistPage, more, 0);
                    foreach (var m in more.Distinct().Take(2))
                        CollectReleases(await Post(browseUrl, BrowseBody(m.Item1, m.Item2), ct, "discography"), all, 0);
                    Remember(fullDiscographies, video.ArtistId, all);
                }
                releases.AddRange(all);
                matching = match();
            }
            if (matching.Count == 0)
            {
                Log.Info("YouTube Music: no single/album named \"" + title + "\" by this artist (" + releases.Select(r => r.Item1).Distinct().Count() + " releases)");
                return null;
            }
            foreach (var album in matching)
            {
                var page = await Post(MusicBase.TrimEnd('/') + "/youtubei/v1/browse?prettyPrint=false", BrowseBody(album), ct, "album page");
                var tracks = new List<object>();
                CollectAll(page, "musicResponsiveListItemRenderer", tracks, 0);
                foreach (var t in tracks)
                {
                    var id = Path(t, "playlistItemData", "videoId") as string;
                    if (string.IsNullOrEmpty(id)) continue;
                    var cols = Path(t, "flexColumns") as IEnumerable;
                    string trackTitle = "";
                    if (cols != null) foreach (var c in cols) { trackTitle = Runs(Path(c, "musicResponsiveListItemFlexColumnRenderer", "text")); break; }
                    double length = 0;
                    var fixedCols = Path(t, "fixedColumns") as IEnumerable;
                    if (fixedCols != null) foreach (var c in fixedCols) { length = ParseClock(Runs(Path(c, "musicResponsiveListItemFixedColumnRenderer", "text"))); if (length > 0) break; }
                    if (!named(trackTitle)) continue;
                    if (length > 0 && Math.Abs(length - video.Duration) > 5) continue;
                    Log.Info("YouTube Music: official audio for " + video.VideoId + " (" + video.Title + ") is " + id + " (" + trackTitle + ", " + (int)length + "s)");
                    return id;
                }
            }
            Log.Info("YouTube Music: no track \"" + title + "\" of about " + (int)video.Duration + "s in " + string.Join(", ", matching));
            return null;
        }

        readonly Dictionary<string, object> artistPages = new Dictionary<string, object>();
        readonly Dictionary<string, List<Tuple<string, string>>> fullDiscographies = new Dictionary<string, List<Tuple<string, string>>>();

        /// <summary>"Show all" links of the artist page's album / single shelves (browseId + params).</summary>
        static void CollectDiscographyLinks(object node, List<Tuple<string, string>> found, int depth)
        {
            if (depth > 60 || node == null) return;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object be;
                if (d.TryGetValue("browseEndpoint", out be)
                    && Path(be, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as string == "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY")
                {
                    var id = Path(be, "browseId") as string;
                    if (!string.IsNullOrEmpty(id)) found.Add(Tuple.Create(id, Path(be, "params") as string ?? ""));
                }
                foreach (var v in d.Values) CollectDiscographyLinks(v, found, depth + 1);
                return;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string)) foreach (var v in list) CollectDiscographyLinks(v, found, depth + 1);
        }

        Dictionary<string, object> BrowseBody(string browseId, string browseParams = null)
        {
            var body = BrowseBodyCore(browseId);
            if (!string.IsNullOrEmpty(browseParams)) body["params"] = browseParams;
            return body;
        }

        Dictionary<string, object> BrowseBodyCore(string browseId)
        {
            return new Dictionary<string, object>
            {
                { "browseId", browseId },
                { "context", new Dictionary<string, object> { { "client", new Dictionary<string, object> {
                    { "clientName", "WEB_REMIX" }, { "clientVersion", WebClientVersion }, { "hl", "ja" } } } } },   // Japanese titles, as in the songs
            };
        }

        static void CollectReleases(object node, List<Tuple<string, string>> found, int depth)
        {
            if (depth > 60 || node == null) return;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object item;
                if (d.TryGetValue("musicTwoRowItemRenderer", out item))
                {
                    var be = Path(item, "navigationEndpoint", "browseEndpoint");
                    var page = Path(be, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as string;
                    var id = Path(be, "browseId") as string;
                    if (page == "MUSIC_PAGE_TYPE_ALBUM" && !string.IsNullOrEmpty(id)) found.Add(Tuple.Create(id, Runs(Path(item, "title"))));
                }
                foreach (var v in d.Values) CollectReleases(v, found, depth + 1);
                return;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string)) foreach (var v in list) CollectReleases(v, found, depth + 1);
        }

        static void CollectAll(object node, string key, List<object> found, int depth)
        {
            if (depth > 60 || node == null) return;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object v;
                if (d.TryGetValue(key, out v)) found.Add(v);
                foreach (var c in d.Values) CollectAll(c, key, found, depth + 1);
                return;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string)) foreach (var c in list) CollectAll(c, key, found, depth + 1);
        }

        static string Runs(object textNode)
        {
            var simple = Path(textNode, "simpleText") as string;
            if (simple != null) return simple;
            var runs = Path(textNode, "runs") as IEnumerable;
            if (runs == null) return "";
            var sb = new StringBuilder();
            foreach (var run in runs) sb.Append(Path(run, "text") as string);
            return sb.ToString();
        }

        /// <summary>"4:51" / "1:02:03" -> seconds (0 when unreadable).</summary>
        internal static double ParseClock(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return 0;
            double total = 0;
            foreach (var part in text.Trim().Split(':'))
            {
                int v;
                if (!int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return 0;
                total = total * 60 + v;
            }
            return total;
        }

        // ---- video description (www.youtube.com) ---------------------------------------------------

        public string YoutubeBase = "https://www.youtube.com/";
        static string WebVersion { get { return "2." + DateTime.UtcNow.AddDays(-2).ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".00.00"; } }

        /// <summary>
        /// The video's description text, plus the video IDs its links point to (YouTube shortens long links in
        /// the visible text, so linked IDs are collected separately). Null when it can't be read.
        /// </summary>
        public async Task<VideoDescription> Description(string videoId, CancellationToken ct)
        {
            VideoDescription known;
            if (Recall(descriptions, videoId, out known)) return known;
            var d = await DescriptionCore(videoId, ct);
            return d == null ? null : Remember(descriptions, videoId, d);
        }

        async Task<VideoDescription> DescriptionCore(string videoId, CancellationToken ct)
        {
            var body = new Dictionary<string, object>
            {
                { "videoId", videoId },
                { "context", new Dictionary<string, object> { { "client", new Dictionary<string, object> {
                    { "clientName", "WEB" }, { "clientVersion", WebVersion } } } } },
            };
            // the player response carries the full description as plain text
            try
            {
                var player = await Post(YoutubeBase.TrimEnd('/') + "/youtubei/v1/player?prettyPrint=false", body, ct, "player");
                var text = Path(player, "videoDetails", "shortDescription") as string;
                if (!string.IsNullOrEmpty(text)) return new VideoDescription { Text = text };
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex) { Log.Write("INFO YouTube player (description) failed: " + ex.Message + ", trying the watch page"); }

            // otherwise the watch-next page: description text + the videos its links point to
            var next = await Post(YoutubeBase.TrimEnd('/') + "/youtubei/v1/next?prettyPrint=false", body, ct, "watch next");
            var desc = Find(next, "attributedDescriptionBodyText", 0) ?? Find(next, "attributedDescription", 0);
            var d = new VideoDescription { Text = Path(desc, "content") as string ?? "" };
            CollectWatchIds(desc, d.LinkedIds, 0);
            return d.Text.Length == 0 && d.LinkedIds.Count == 0 ? null : d;
        }

        static void CollectWatchIds(object node, List<string> ids, int depth)
        {
            if (depth > 30 || node == null) return;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object we;
                if (d.TryGetValue("watchEndpoint", out we))
                {
                    var id = Path(we, "videoId") as string;
                    if (!string.IsNullOrEmpty(id) && !ids.Contains(id)) ids.Add(id);
                }
                foreach (var v in d.Values) CollectWatchIds(v, ids, depth + 1);
                return;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string)) foreach (var v in list) CollectWatchIds(v, ids, depth + 1);
        }

        static object FindWhere(object node, string key, Func<object, bool> match, int depth)
        {
            if (depth > 40 || node == null) return null;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object v;
                if (d.TryGetValue(key, out v) && match(v)) return v;
                foreach (var c in d.Values) { var hit = FindWhere(c, key, match, depth + 1); if (hit != null) return hit; }
                return null;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string))
                foreach (var c in list) { var hit = FindWhere(c, key, match, depth + 1); if (hit != null) return hit; }
            return null;
        }

        /// <summary>Timed lines from a /browse response, or null when there are none (plain lyrics or nothing).</summary>
        static LyricsResult Parse(object response)
        {
            var timed = Find(Path(response, "contents"), "timedLyricsData", 0) as IEnumerable;
            if (timed == null) return null;
            var lines = new List<LyricLine>();
            foreach (var item in timed)
            {
                var start = Path(item, "cueRange", "startTimeMilliseconds");
                if (start == null) continue;
                double ms;
                if (!double.TryParse(Convert.ToString(start, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out ms)) continue;
                var text = (Path(item, "lyricLine") as string ?? "").Trim();
                if (text == "♪") text = "";
                lines.Add(new LyricLine { TimeMs = (int)Math.Max(0, ms), Text = text });
            }
            if (lines.Count == 0) return null;
            return new LyricsResult { Lines = lines.OrderBy(l => l.TimeMs).ToList(), Source = "YouTube Music" };
        }

        /// <summary>The lyrics tab's browseId, wherever it sits in the watch-next response.</summary>
        static string LyricsBrowseId(object node, int depth)
        {
            if (depth > 30 || node == null) return null;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object be;
                if (d.TryGetValue("browseEndpoint", out be)
                    && Path(be, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as string == "MUSIC_PAGE_TYPE_TRACK_LYRICS")
                    return Path(be, "browseId") as string;
                foreach (var v in d.Values) { var id = LyricsBrowseId(v, depth + 1); if (id != null) return id; }
                return null;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string))
                foreach (var v in list) { var id = LyricsBrowseId(v, depth + 1); if (id != null) return id; }
            return null;
        }

        static object Find(object node, string key, int depth)
        {
            if (depth > 30 || node == null) return null;
            var d = node as IDictionary<string, object>;
            if (d != null)
            {
                object v;
                if (d.TryGetValue(key, out v)) return v;
                foreach (var c in d.Values) { var hit = Find(c, key, depth + 1); if (hit != null) return hit; }
                return null;
            }
            var list = node as IEnumerable;
            if (list != null && !(node is string))
                foreach (var c in list) { var hit = Find(c, key, depth + 1); if (hit != null) return hit; }
            return null;
        }

        async Task<object> Post(string url, object body, CancellationToken ct, string label)
        {
            var payload = json.Serialize(body);
            for (int hop = 0; hop < 4; hop++)
            {
                using (var req = new HttpRequestMessage(HttpMethod.Post, url))
                {
                    req.Content = new StringContent(payload, Encoding.UTF8, "application/json");
                    using (var resp = await http.SendAsync(req, ct))
                    {
                        int code = (int)resp.StatusCode;
                        if (code >= 300 && code < 400 && resp.Headers.Location != null)
                        {
                            var loc = resp.Headers.Location.IsAbsoluteUri ? resp.Headers.Location : new Uri(new Uri(url), resp.Headers.Location);
                            url = loc.ToString();
                            continue;   // re-send the same POST to the new address
                        }
                        if (!resp.IsSuccessStatusCode)
                            throw new HttpRequestException("YouTube Music " + label + " " + code);
                        return json.DeserializeObject(await resp.Content.ReadAsStringAsync());
                    }
                }
            }
            throw new HttpRequestException("too many redirects");
        }

        static object Path(object node, params string[] keys)
        {
            foreach (var k in keys)
            {
                var d = node as IDictionary<string, object>;
                if (d == null) return null;
                object v;
                if (!d.TryGetValue(k, out v)) return null;
                node = v;
            }
            return node;
        }

        public void Dispose() { http.Dispose(); }
    }
}
