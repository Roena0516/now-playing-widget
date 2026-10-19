using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    internal enum PearStatus { Starting, Waiting, Authorizing, Denied, Connected }

    internal sealed class SongInfo
    {
        public string Title = "";
        public string AltTitle = "";
        public List<string> Tags = new List<string>();
        public string Artist = "";
        public string Album = "";
        public string ImageSrc = "";
        public string VideoId = "";
        /// <summary>AUDIO, ORIGINAL_MUSIC_VIDEO, USER_GENERATED_CONTENT, PODCAST_EPISODE, OTHER_VIDEO (Pear's MediaType)</summary>
        public string MediaType = "";
        public double Duration;
        public double Elapsed;
        public bool IsPaused;
        public bool HasData { get { return !string.IsNullOrEmpty(Title) || !string.IsNullOrEmpty(VideoId); } }

        /// <summary>A copy showing another title (the card's display title; lookups keep Pear's).</summary>
        public SongInfo WithTitle(string title)
        {
            var copy = (SongInfo)MemberwiseClone();
            copy.Title = title;
            return copy;
        }
    }

    /// <summary>
    /// Talks to the Pear Desktop "API Server" plugin:
    ///   POST /auth/{id}                -> { accessToken }   (Pear shows an allow/deny dialog the first time)
    ///   WS   /api/v1/ws?token=...      -> PLAYER_INFO / VIDEO_CHANGED / PLAYER_STATE_CHANGED / POSITION_CHANGED ...
    ///   POST /api/v1/next | previous | toggle-play   (Authorization: Bearer token)
    /// </summary>
    internal sealed class PearClient : IDisposable
    {
        const string ClientId = "pear-now-playing";

        readonly SynchronizationContext ui;
        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly SemaphoreSlim retrySignal = new SemaphoreSlim(0);
        CancellationTokenSource cts;
        ClientWebSocket socket;
        Config cfg;
        string token;

        public PearStatus Status { get; private set; }
        public SongInfo Current { get; private set; }
        public bool IsPlaying { get; private set; }

        public event Action<PearStatus> StatusChanged;
        public event Action<SongInfo, bool> SongUpdated;   // (song, isNewSong)
        public event Action<bool> PlayStateChanged;         // isPlaying
        public event Action<double> PositionChanged;        // seconds

        public PearClient(SynchronizationContext ui, Config cfg)
        {
            this.ui = ui;
            this.cfg = cfg;
            http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromMinutes(3) };
            Current = new SongInfo();
        }

        public void Start()
        {
            cts = new CancellationTokenSource();
            var ct = cts.Token;
            Task.Run(() => RunLoop(ct));
        }

        /// <summary>Apply new config (host/port changes) and reconnect.</summary>
        public void Reconnect(Config newCfg)
        {
            cfg = newCfg;
            Abort();
            retrySignal.Release();
        }

        /// <summary>Called from the tray menu after the user was denied, to ask Pear again.</summary>
        public void RetryAuth()
        {
            retrySignal.Release();
            Abort();
        }

        void Abort()
        {
            try { var s = socket; if (s != null) s.Abort(); } catch { }
        }

        async Task RunLoop(CancellationToken ct)
        {
            SetStatus(PearStatus.Starting);
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    token = Config.ReadToken();
                    if (string.IsNullOrEmpty(token))
                    {
                        var result = await RequestToken(ct);
                        if (result == AuthResult.Unreachable) { SetStatus(PearStatus.Waiting); await Wait(3000, ct); continue; }
                        if (result == AuthResult.Denied)
                        {
                            SetStatus(PearStatus.Denied);
                            // wait until the user asks to retry from the tray menu
                            await retrySignal.WaitAsync(ct);
                            continue;
                        }
                    }

                    bool tokenRejected = await RunSocket(ct);
                    if (tokenRejected)
                    {
                        Log.Info("token rejected by Pear, requesting a new one");
                        Config.WriteToken(null);
                        token = null;
                        continue;
                    }
                    SetStatus(PearStatus.Waiting);
                    await Wait(2000, ct);
                }
                catch (OperationCanceledException) { if (ct.IsCancellationRequested) break; }
                catch (Exception ex)
                {
                    Log.Error("loop", ex);
                    SetStatus(PearStatus.Waiting);
                    try { await Wait(3000, ct); } catch (OperationCanceledException) { break; }
                }
            }
        }

        async Task Wait(int ms, CancellationToken ct)
        {
            // wake up early when Reconnect()/RetryAuth() is called
            await retrySignal.WaitAsync(ms, ct);
        }

        enum AuthResult { Ok, Denied, Unreachable }

        async Task<AuthResult> RequestToken(CancellationToken ct)
        {
            try
            {
                var post = http.PostAsync(cfg.BaseHttp + "/auth/" + ClientId, new StringContent(""), ct);
                // A refused connection fails at once. If Pear holds the request open, it is showing its
                // allow/deny dialog, and only then do we tell the user to click "허용".
                if (await Task.WhenAny(post, Task.Delay(800, ct)) != post) SetStatus(PearStatus.Authorizing);
                using (var resp = await post)
                {
                    if (resp.StatusCode == HttpStatusCode.Forbidden) return AuthResult.Denied;
                    if (!resp.IsSuccessStatusCode)
                    {
                        Log.Info("auth returned " + (int)resp.StatusCode);
                        return AuthResult.Unreachable;
                    }
                    var body = await resp.Content.ReadAsStringAsync();
                    var obj = json.DeserializeObject(body) as IDictionary<string, object>;
                    var t = obj != null ? Str(obj, "accessToken") : "";
                    if (string.IsNullOrEmpty(t)) return AuthResult.Unreachable;
                    token = t;
                    Config.WriteToken(t);
                    return AuthResult.Ok;
                }
            }
            catch (HttpRequestException) { return AuthResult.Unreachable; }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { return AuthResult.Unreachable; }
        }

        /// <returns>true if Pear rejected our token</returns>
        async Task<bool> RunSocket(CancellationToken ct)
        {
            using (var ws = new ClientWebSocket())
            {
                ws.Options.Proxy = null;
                ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
                // Pear 3.12+ reads the token from the query and closes with 1008 otherwise; 3.11 checks a bearer
                // header on the upgrade request and ignores the query. Send both.
                if (!string.IsNullOrEmpty(token)) ws.Options.SetRequestHeader("Authorization", "Bearer " + token);
                socket = ws;
                var uri = new Uri(cfg.BaseWs + "/api/v1/ws?token=" + Uri.EscapeDataString(token ?? ""));
                try { await ws.ConnectAsync(uri, ct); }
                catch (WebSocketException) { return false; }

                var buffer = new byte[64 * 1024];
                var acc = new MemoryStream();
                bool gotMessage = false;
                try
                {
                    while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
                    {
                        var r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
                        if (r.MessageType == WebSocketMessageType.Close)
                        {
                            if (r.CloseStatus == WebSocketCloseStatus.PolicyViolation) return true; // 1008 Unauthorized
                            return false;
                        }
                        acc.Write(buffer, 0, r.Count);
                        if (!r.EndOfMessage) continue;
                        var text = Encoding.UTF8.GetString(acc.ToArray());
                        acc.SetLength(0);
                        if (!gotMessage) { gotMessage = true; SetStatus(PearStatus.Connected); }
                        try { Handle(text); } catch (Exception ex) { Log.Error("handle message", ex); }
                    }
                }
                catch (WebSocketException) { }
                catch (OperationCanceledException) { if (ct.IsCancellationRequested) throw; }
                finally { socket = null; }
                return false;
            }
        }

        void Handle(string text)
        {
            var msg = json.DeserializeObject(text) as IDictionary<string, object>;
            if (msg == null) return;
            var type = Str(msg, "type");
            object songObj;
            msg.TryGetValue("song", out songObj);
            var songDict = songObj as IDictionary<string, object>;

            switch (type)
            {
                case "PLAYER_INFO":
                case "VIDEO_CHANGED":
                {
                    bool isNew = false;
                    if (songDict != null)
                    {
                        var s = ParseSong(songDict);
                        isNew = s.VideoId != Current.VideoId || s.Title != Current.Title;
                        Current = s;
                    }
                    if (msg.ContainsKey("isPlaying")) IsPlaying = Bool(msg, "isPlaying");
                    else if (songDict != null) IsPlaying = !Current.IsPaused;
                    if (msg.ContainsKey("position")) Current.Elapsed = Num(msg, "position");
                    var snapshot = Current;
                    Post(() => { var h = SongUpdated; if (h != null) h(snapshot, isNew); });
                    break;
                }
                case "PLAYER_STATE_CHANGED":
                {
                    bool playing = Bool(msg, "isPlaying");
                    bool changed = playing != IsPlaying;
                    IsPlaying = playing;
                    Current.IsPaused = !playing;
                    if (msg.ContainsKey("position")) Current.Elapsed = Num(msg, "position");
                    if (changed) Post(() => { var h = PlayStateChanged; if (h != null) h(playing); });
                    break;
                }
                case "POSITION_CHANGED":
                {
                    double pos = Num(msg, "position");
                    // At the end of a song Pear reports position 0 about 0.3s before VIDEO_CHANGED names the next
                    // song, so for a moment the old song looks rewound (its lyrics scrolled back to the top).
                    // VIDEO_CHANGED brings the position itself; a song played again gets it from the next tick.
                    if (IsRewindAtEnd(pos, Current.Elapsed, Current.Duration)) break;
                    Current.Elapsed = pos;
                    Post(() => { var h = PositionChanged; if (h != null) h(pos); });
                    break;
                }
            }
        }

        /// <summary>Position 0 while the song was in its last seconds: the next song is starting, not a seek.</summary>
        internal static bool IsRewindAtEnd(double pos, double last, double duration)
        {
            return pos < 1 && duration > 0 && last >= duration - 3;
        }

        static SongInfo ParseSong(IDictionary<string, object> d)
        {
            var s = new SongInfo();
            s.Title = Str(d, "title");
            s.AltTitle = Str(d, "alternativeTitle");
            if (string.IsNullOrEmpty(s.Title)) s.Title = s.AltTitle;
            object tags;
            if (d.TryGetValue("tags", out tags) && tags is IEnumerable && !(tags is string))
                foreach (var t in (IEnumerable)tags) if (t is string && ((string)t).Length > 0) s.Tags.Add((string)t);
            s.Artist = Str(d, "artist");
            s.Album = Str(d, "album");
            s.ImageSrc = Str(d, "imageSrc");
            s.VideoId = Str(d, "videoId");
            s.MediaType = Str(d, "mediaType");
            s.Duration = Num(d, "songDuration");
            s.Elapsed = Num(d, "elapsedSeconds");
            s.IsPaused = Bool(d, "isPaused");
            return s;
        }

        // ---- player controls -------------------------------------------------

        public void Next() { Fire("/api/v1/next"); }
        public void Previous() { Fire("/api/v1/previous"); }
        public void TogglePlay() { Fire("/api/v1/toggle-play"); }

        void Fire(string path)
        {
            Task.Run(async () =>
            {
                try
                {
                    using (var req = new HttpRequestMessage(HttpMethod.Post, cfg.BaseHttp + path))
                    {
                        if (!string.IsNullOrEmpty(token)) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                        req.Content = new StringContent("");
                        using (var resp = await http.SendAsync(req))
                        {
                            if (resp.StatusCode == HttpStatusCode.Unauthorized)
                            {
                                Config.WriteToken(null);
                                token = null;
                                Abort();
                            }
                        }
                    }
                }
                catch (Exception ex) { Log.Error("control " + path, ex); }
            });
        }

        /// <summary>
        /// The next song in Pear's queue (GET /api/v1/queue/next): title, artist, video ID and length only.
        /// Null when there is no next song or Pear can't be asked.
        /// </summary>
        public async Task<SongInfo> GetNextSong(CancellationToken ct)
        {
            if (string.IsNullOrEmpty(token)) return null;
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
            using (var req = new HttpRequestMessage(HttpMethod.Get, cfg.BaseHttp + "/api/v1/queue/next"))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(10));
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                using (var resp = await http.SendAsync(req, timeout.Token))
                {
                    if (resp.StatusCode != HttpStatusCode.OK) return null;   // 204 = nothing queued
                    var d = json.DeserializeObject(await resp.Content.ReadAsStringAsync()) as IDictionary<string, object>;
                    if (d == null) return null;
                    var s = new SongInfo { Title = Str(d, "title"), VideoId = Str(d, "videoId") };
                    s.Artist = FirstRun(d, "shortBylineText");
                    s.Duration = YtmLyrics.ParseClock(FirstRun(d, "lengthText"));
                    s.MediaType = "UNKNOWN";   // the queue doesn't say; cover detection goes by the title only
                    return string.IsNullOrEmpty(s.VideoId) || string.IsNullOrEmpty(s.Title) ? null : s;
                }
            }
        }

        static string FirstRun(IDictionary<string, object> d, string key)
        {
            object node;
            if (!d.TryGetValue(key, out node)) return "";
            var nd = node as IDictionary<string, object>;
            if (nd == null) return "";
            object simple;
            if (nd.TryGetValue("simpleText", out simple) && simple is string) return (string)simple;
            object runs;
            if (nd.TryGetValue("runs", out runs) && runs is IEnumerable)
                foreach (var r in (IEnumerable)runs)
                {
                    var rd = r as IDictionary<string, object>;
                    object t;
                    if (rd != null && rd.TryGetValue("text", out t) && t is string && ((string)t).Trim().Length > 0) return ((string)t).Trim();
                }
            return "";
        }

        // ---- helpers ---------------------------------------------------------

        void SetStatus(PearStatus s)
        {
            if (Status == s) return;
            Status = s;
            Post(() => { var h = StatusChanged; if (h != null) h(s); });
        }

        void Post(Action a) { ui.Post(_ => a(), null); }

        static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v != null && !(v is IDictionary) ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
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

        public void Dispose()
        {
            try { if (cts != null) cts.Cancel(); } catch { }
            Abort();
            http.Dispose();
        }
    }
}
