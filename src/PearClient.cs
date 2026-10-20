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
    /// <summary>NotLinked: no token yet, and Pear isn't asked for one until the user picks "Pear Desktop 연결 요청".</summary>
    internal enum PearStatus { Starting, Waiting, Authorizing, Denied, Connected, NotLinked }

    /// <summary>Where songs come from: Pear Desktop's API server, or YouTube Music in a web browser (BrowserSource).</summary>
    internal enum SongSource { Pear, Browser }

    /// <summary>One source's player: its song and whether it plays.</summary>
    internal sealed class PlayerState
    {
        public SongInfo Current = new SongInfo();
        public bool IsPlaying;
        readonly PositionFilter jumps = new PositionFilter();

        internal enum Change { None, Song, PlayState, Position }

        /// <summary>One message in Pear's WebSocket format (the browser source speaks it too); what it changed.</summary>
        public Change Apply(IDictionary<string, object> msg)
        {
            object songObj;
            msg.TryGetValue("song", out songObj);
            var songDict = songObj as IDictionary<string, object>;
            switch (PearClient.Str(msg, "type"))
            {
                case "PLAYER_INFO":
                case "VIDEO_CHANGED":
                    if (songDict != null) Current = PearClient.ParseSong(songDict);
                    if (msg.ContainsKey("isPlaying")) IsPlaying = PearClient.Bool(msg, "isPlaying");
                    else if (songDict != null) IsPlaying = !Current.IsPaused;
                    if (msg.ContainsKey("position")) Current.Elapsed = PearClient.Num(msg, "position");
                    jumps.Reset();
                    return Change.Song;
                case "PLAYER_STATE_CHANGED":
                {
                    bool playing = PearClient.Bool(msg, "isPlaying");
                    bool changed = playing != IsPlaying;
                    IsPlaying = playing;
                    Current.IsPaused = !playing;
                    jumps.Reset();
                    if (msg.ContainsKey("position")) Current.Elapsed = PearClient.Num(msg, "position");
                    return changed ? Change.PlayState : Change.None;
                }
                case "POSITION_CHANGED":
                {
                    double pos = PearClient.Num(msg, "position");
                    if (!jumps.Accept(pos, Current.Elapsed, DateTime.UtcNow)) return Change.None;
                    Current.Elapsed = pos;
                    return Change.Position;
                }
            }
            return Change.None;
        }
    }

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

        /// <summary>A copy with another alternative title (to search lyrics under the original title too).</summary>
        public SongInfo WithAltTitle(string altTitle)
        {
            var copy = (SongInfo)MemberwiseClone();
            copy.AltTitle = altTitle;
            return copy;
        }
    }

    /// <summary>
    /// The player whose song is shown: Pear Desktop, or YouTube Music in a web browser (BrowserSource, messages in
    /// Pear's format), whichever started playing last (Config.Source "auto"; "pear" / "browser" use one only).
    /// Talks to the Pear Desktop "API Server" plugin:
    ///   POST /auth/{id}                -> { accessToken }   (Pear shows an allow/deny dialog the first time)
    ///   WS   /api/v1/ws?token=...      -> PLAYER_INFO / VIDEO_CHANGED / PLAYER_STATE_CHANGED / POSITION_CHANGED ...
    ///   POST /api/v1/next | previous | toggle-play   (Authorization: Bearer token)
    /// </summary>
    internal sealed class PearClient : IDisposable
    {
        // the name Pear shows in its allow dialog and keeps the permission under; kept from the app's old name so
        // updating doesn't ask again
        const string ClientId = "pear-now-playing";

        readonly SynchronizationContext ui;
        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly SemaphoreSlim retrySignal = new SemaphoreSlim(0);
        CancellationTokenSource cts;
        ClientWebSocket socket;
        Config cfg;
        string token;
        readonly object gate = new object();
        readonly PlayerState pear = new PlayerState(), browserPlayer = new PlayerState();
        readonly BrowserSource browser;
        bool browserRunning;
        string shownKey = "";

        /// <summary>Pear's connection state.</summary>
        public PearStatus Status { get; private set; }
        /// <summary>The source of the song shown.</summary>
        public SongSource Source { get; private set; }
        PlayerState Shown { get { return Source == SongSource.Browser ? browserPlayer : pear; } }
        public SongInfo Current { get { lock (gate) return Shown.Current; } }
        public bool IsPlaying { get { lock (gate) return Shown.IsPlaying; } }
        /// <summary>The browser playing YouTube Music, or null.</summary>
        public string BrowserName { get { return browserRunning ? browser.Browser : null; } }

        /// <summary>Pear's connection state changed.</summary>
        public event Action<PearStatus> StatusChanged;
        /// <summary>A message for the user (shown as an info card).</summary>
        public event Action<string> Notice;

        /// <summary>
        /// Pear is asked for a token only when the user picks "Pear Desktop 연결 요청", or when a token Pear gave before
        /// was rejected (it expired): never on its own at first start, so Pear's allow dialog doesn't pop up for users of
        /// the browser alone, and nothing is asked again and again while Pear isn't there.
        /// </summary>
        volatile bool linkRequested;
        /// <summary>The status line changed (Pear's state, the browser playing, or the source shown).</summary>
        public event Action StatusLineChanged;
        public event Action<SongInfo, bool> SongUpdated;   // (song, isNewSong)
        public event Action<bool> PlayStateChanged;         // isPlaying
        public event Action<double> PositionChanged;        // seconds

        public PearClient(SynchronizationContext ui, Config cfg, YtmLyrics ytm)
        {
            this.ui = ui;
            this.cfg = cfg;
            http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromMinutes(3) };
            browser = new BrowserSource(ytm);
            browser.Message = m => HandleMessage(m, SongSource.Browser);
            browser.BrowserChanged = () => Post(RaiseLine);
        }

        public void Start() { ApplySource(); }

        /// <summary>Start or stop the Pear connection and the browser source as Config.Source says.</summary>
        void ApplySource()
        {
            bool usePear = cfg.Source != "browser", useBrowser = cfg.Source != "pear";
            if (pearSilenceWatch == null) pearSilenceWatch = new Timer(_ => { try { CheckPearSilence(DateTime.UtcNow); } catch (Exception ex) { Log.Error("pear silence", ex); } }, null, 500, 500);
            if (usePear && cts == null)
            {
                cts = new CancellationTokenSource();
                var ct = cts.Token;
                Task.Run(() => RunLoop(ct));
            }
            else if (!usePear && cts != null)
            {
                cts.Cancel(); cts = null;
                Abort();
                lock (gate) pear.IsPlaying = false;
                SetStatus(PearStatus.Starting);
            }
            if (useBrowser && !browserRunning) { browserRunning = true; browser.Start(); }
            else if (!useBrowser && browserRunning)
            {
                browserRunning = false; browser.Stop();
                lock (gate) browserPlayer.IsPlaying = false;
            }
            Post(RaiseLine);
        }

        /// <summary>Apply new config (host/port or source changes) and reconnect.</summary>
        public void Reconnect(Config newCfg)
        {
            cfg = newCfg;
            Abort();
            retrySignal.Release();
            ApplySource();
        }

        /// <summary>"Pear Desktop 연결 요청" in the tray menu: ask Pear for a token now (its allow dialog the first time).</summary>
        public void RetryAuth()
        {
            linkRequested = true;
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
                        if (!linkRequested)
                        {
                            SetStatus(PearStatus.NotLinked);
                            await retrySignal.WaitAsync(ct);   // until "Pear Desktop 연결 요청" (or a reconnect)
                            continue;
                        }
                        linkRequested = false;
                        // Pear not there (not running, or its API server plugin off): say so once. (On Windows a refused
                        // local connection takes about 2 seconds, which looked like Pear holding the request open for
                        // its allow dialog: "'허용'을 눌러 주십시오" every few seconds without Pear.)
                        var result = await Reachable(ct) ? await RequestToken(ct) : AuthResult.Unreachable;
                        if (result == AuthResult.Unreachable)
                        {
                            Log.Info("Pear link requested, but its API server doesn't answer at " + cfg.BaseHttp);
                            SetStatus(PearStatus.NotLinked);
                            Post(() => { var h = Notice; if (h != null) h("Pear Desktop에 연결하지 못했습니다. Pear Desktop이 실행 중이고 API 서버 플러그인이 켜져 있는지 확인해 주십시오"); });
                            continue;
                        }
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
                        linkRequested = true;   // linked before: a new token is asked for at once
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

        /// <summary>Whether Pear's API server answers at all (any HTTP status will do).</summary>
        async Task<bool> Reachable(CancellationToken ct)
        {
            try
            {
                using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    timeout.CancelAfter(TimeSpan.FromSeconds(4));
                    using (await http.GetAsync(cfg.BaseHttp + "/api/v1/song", timeout.Token)) return true;
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { return false; }
        }

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
            if (msg != null) HandleMessage(msg, SongSource.Pear);
        }

        /// <summary>
        /// A message from Pear (or, in the same format, from the browser source). The song shown is the source's that
        /// started playing last: a source that starts playing (or plays a new song) takes over, and one that plays
        /// takes over from a paused one. Same as PearClient.handle in macos/Sources/PearClient.swift.
        /// </summary>
        internal void HandleMessage(IDictionary<string, object> msg, SongSource origin)
        {
            lock (gate)
            {
                if (origin == SongSource.Pear && NotePearMessage(msg)) return;
                var state = origin == SongSource.Browser ? browserPlayer : pear;
                bool wasPlaying = state.IsPlaying;
                string before = Key(state.Current);
                var change = state.Apply(msg);
                var shown = Shown;
                bool started = state.IsPlaying && (!wasPlaying || Key(state.Current) != before);
                if (origin != Source && state.Current.HasData && (started || !shown.Current.HasData || (!shown.IsPlaying && state.IsPlaying)))
                {
                    Log.Info(origin == SongSource.Browser ? "showing the song playing in " + (browser.Browser ?? "the browser") : "showing the song playing in Pear");
                    Source = origin;
                    change = PlayerState.Change.Song;
                    Post(RaiseLine);
                }
                if (origin != Source) return;
                switch (change)
                {
                    case PlayerState.Change.Song:
                    {
                        var snapshot = state.Current;
                        bool isNew = Key(snapshot) != shownKey;
                        shownKey = Key(snapshot);
                        bool playing = state.IsPlaying;
                        Post(() => { var h = SongUpdated; if (h != null) h(snapshot, isNew); });
                        if (!isNew) Post(() => { var h = PlayStateChanged; if (h != null) h(playing); });
                        break;
                    }
                    case PlayerState.Change.PlayState:
                    {
                        bool playing = state.IsPlaying;
                        Post(() => { var h = PlayStateChanged; if (h != null) h(playing); });
                        break;
                    }
                    case PlayerState.Change.Position:
                    {
                        double pos = state.Current.Elapsed;
                        Post(() => { var h = PositionChanged; if (h != null) h(pos); });
                        break;
                    }
                }
            }
        }

        static string Key(SongInfo s) { return s.VideoId + "|" + s.Title; }

        // Pear 3.12.0 sends no PLAYER_STATE_CHANGED when the song is paused or played again, and its own song info keeps
        // saying it plays (isPaused stays false, also in PLAYER_INFO and /api/v1/song; seen 2026-10-20). It does stop
        // sending the position every second while paused, so that silence is taken for a pause, and a position coming
        // after it for playing again. A Pear that does send the state is followed as before. Same as the macOS version.
        DateTime pearLastTick = DateTime.MinValue;
        bool pearPauseGuessed;
        Timer pearSilenceWatch;
        internal static readonly TimeSpan PearSilence = TimeSpan.FromSeconds(2.5);

        /// <summary>Bookkeeping for each Pear message (under the gate); true when handled here (a position resuming a guessed pause).</summary>
        bool NotePearMessage(IDictionary<string, object> msg)
        {
            switch (Str(msg, "type"))
            {
                case "PLAYER_STATE_CHANGED": pearPauseGuessed = false; break;
                case "PLAYER_INFO":
                case "VIDEO_CHANGED": pearLastTick = DateTime.UtcNow; pearPauseGuessed = false; break;
                case "POSITION_CHANGED":
                    pearLastTick = DateTime.UtcNow;
                    if (pearPauseGuessed && !pear.IsPlaying)
                    {
                        pearPauseGuessed = false;
                        HandleMessage(new Dictionary<string, object> { { "type", "PLAYER_STATE_CHANGED" }, { "isPlaying", true }, { "position", Num(msg, "position") } }, SongSource.Pear);
                        return true;
                    }
                    break;
            }
            return false;
        }

        /// <summary>Pear's song plays but no position came for a while: paused at the last position Pear sent.</summary>
        internal void CheckPearSilence(DateTime utcNow)
        {
            lock (gate)
            {
                if (!pear.IsPlaying || !pear.Current.HasData || pearLastTick == DateTime.MinValue || utcNow - pearLastTick <= PearSilence) return;
                HandleMessage(new Dictionary<string, object> { { "type", "PLAYER_STATE_CHANGED" }, { "isPlaying", false }, { "position", pear.Current.Elapsed } }, SongSource.Pear);
                pearPauseGuessed = true;
            }
        }

        internal static SongInfo ParseSong(IDictionary<string, object> d)
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

        public void Next() { if (BrowserShown) browser.Control("next"); else Fire("/api/v1/next"); }
        public void Previous() { if (BrowserShown) browser.Control("previous"); else Fire("/api/v1/previous"); }
        public void TogglePlay() { if (BrowserShown) browser.Control("toggle-play"); else Fire("/api/v1/toggle-play"); }
        bool BrowserShown { get { return Source == SongSource.Browser && browserRunning; } }

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
            if (Source == SongSource.Browser) return browserRunning ? await browser.NextSong(ct) : null;
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
            // Pear is gone: its song no longer plays (so a browser playing takes over)
            if (s != PearStatus.Connected) lock (gate) pear.IsPlaying = false;
            Post(() => { var h = StatusChanged; if (h != null) h(s); RaiseLine(); });
        }

        void RaiseLine() { var h = StatusLineChanged; if (h != null) h(); }

        /// <summary>
        /// The status line: the browser while its song is shown (or Pear isn't connected), else Pear's state. Same
        /// wording as the macOS version's PearClient.status.
        /// </summary>
        public string StatusLine
        {
            get
            {
                var name = BrowserName;
                if (name != null && (Source == SongSource.Browser || Status != PearStatus.Connected)) return "브라우저 YouTube Music에 연결됨 (" + name + ")";
                if (cfg.Source == "browser") return "브라우저의 YouTube Music 기다리는 중";
                if (cfg.Source == "auto" && Status == PearStatus.Waiting) return "YouTube Music 기다리는 중 (브라우저, Pear Desktop)";
                if (cfg.Source == "auto" && Status == PearStatus.NotLinked) return "브라우저의 YouTube Music 기다리는 중";
                switch (Status)
                {
                    case PearStatus.Waiting: return "Pear Desktop 기다리는 중 (API 서버 확인)";
                    case PearStatus.Authorizing: return "Pear Desktop에서 허용 대기 중";
                    case PearStatus.Denied: return "Pear Desktop에서 연결 거부됨";
                    case PearStatus.Connected: return "Pear Desktop에 연결됨";
                    case PearStatus.NotLinked: return "Pear Desktop 연결 안 됨 (메뉴에서 연결 요청)";
                    default: return "연결 준비 중";
                }
            }
        }

        /// <summary>Whether a player is connected (the card says "재생 중인 곡이 없습니다" then, not the connection state).</summary>
        public bool IsConnected { get { return BrowserName != null || Status == PearStatus.Connected; } }

        void Post(Action a) { ui.Post(_ => a(), null); }

        internal static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v != null && !(v is IDictionary) ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
        }

        internal static double Num(IDictionary<string, object> d, string k)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null) return 0;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return 0; }
        }

        internal static bool Bool(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is bool && (bool)v;
        }

        public void Dispose()
        {
            try { if (cts != null) cts.Cancel(); } catch { }
            try { if (pearSilenceWatch != null) pearSilenceWatch.Dispose(); } catch { }
            Abort();
            try { browser.Dispose(); } catch { }
            http.Dispose();
        }
    }

    /// <summary>
    /// When a song ends Pear reports a position for the old song just before VIDEO_CHANGED names the next one: usually
    /// 0 (about 0.3-0.7s before), sometimes first another value (2026-10-20: 115 after 190, the next song being 114s
    /// long). Taken as is, the old song looks rewound: its lyrics scroll back, then the next song's start. So a
    /// position that goes back is held for a tick and applied only when the next one carries on from it (a seek back,
    /// a song on repeat); VIDEO_CHANGED brings the new song's position itself.
    /// </summary>
    internal sealed class PositionFilter
    {
        double? held;
        DateTime heldAt;

        public void Reset() { held = null; }

        /// <summary>Whether to apply this position now.</summary>
        /// <param name="last">the position shown so far</param>
        public bool Accept(double pos, double last, DateTime now)
        {
            if (pos >= last - 2) { held = null; return true; }   // playing on, or a seek forward
            if (held.HasValue && pos >= held.Value - 0.5 && pos <= held.Value + (now - heldAt).TotalSeconds + 2)
            {
                held = null;
                return true;
            }
            held = pos;
            heldAt = now;
            return false;
        }
    }
}
