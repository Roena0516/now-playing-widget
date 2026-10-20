using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PearNowPlaying
{
    /// <summary>
    /// Windows Runtime calls by reflection: the build has no Windows.winmd to compile against (it is built with
    /// Mono's reference assemblies too), and .NET Framework 4.8 resolves WinRT types by name at run time, the way
    /// Windows PowerShell 5.1 does ([Windows.Media.Control.…, Windows.Media, ContentType=WindowsRuntime]).
    /// </summary>
    internal static class WinRt
    {
        static readonly MethodInfo asTask = FindAsTask();

        static MethodInfo FindAsTask()
        {
            try
            {
                var ext = Type.GetType("System.WindowsRuntimeSystemExtensions, System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089");
                return ext == null ? null : ext.GetMethods().FirstOrDefault(m => m.Name == "AsTask" && m.IsGenericMethodDefinition
                    && m.GetParameters().Length == 1 && m.GetParameters()[0].ParameterType.Name == "IAsyncOperation`1");
            }
            catch (Exception ex) { Log.Write("INFO Windows Runtime not available: " + ex.Message); return null; }
        }

        /// <summary>A type of Windows.Media.Control (the system media transport controls), or null.</summary>
        public static Type MediaControl(string name)
        {
            try { return Type.GetType("Windows.Media.Control." + name + ", Windows.Media, ContentType=WindowsRuntime"); }
            catch { return null; }
        }

        public static bool CanAwait { get { return asTask != null; } }

        /// <summary>The result of an IAsyncOperation&lt;T&gt;.</summary>
        public static async Task<object> Await(object operation, Type result)
        {
            var task = (Task)asTask.MakeGenericMethod(result).Invoke(null, new[] { operation });
            await task.ConfigureAwait(false);
            return task.GetType().GetProperty("Result").GetValue(task);
        }

        public static object Call(Type type, object target, string method)
        {
            return type.GetMethod(method, Type.EmptyTypes).Invoke(target, null);
        }

        public static object Get(Type type, object target, string property)
        {
            return type.GetProperty(property).GetValue(target);
        }
    }

    /// <summary>What Windows says a browser is playing (the system media transport controls, SMTC).</summary>
    internal sealed class MediaInfo
    {
        /// <summary>The session's app ID ("Chrome", "MSEdge", Firefox's "308046B0AF4A39CB" …).</summary>
        public string App = "";
        public BrowserNames.Browser Browser;
        public string Title = "", Artist = "", Album = "";
        public double Duration;
        /// <summary>The position at <see cref="Updated"/> (UTC); it moves on at <see cref="Rate"/> while playing.</summary>
        public double Position;
        public DateTime Updated;
        public double Rate = 1;
        public bool Playing;

        public double PositionAt(DateTime utcNow)
        {
            if (!Playing || Updated == DateTime.MinValue) return Math.Max(0, Position);
            return Math.Max(0, Position + (utcNow - Updated).TotalSeconds * (Rate > 0 ? Rate : 1));
        }
    }

    /// <summary>Browsers by their SMTC app ID: the name shown, and the process whose windows hold the tabs.</summary>
    internal static class BrowserNames
    {
        internal sealed class Browser { public string Name, Process; }

        static readonly string[][] known =
        {
            new[] { "msedge", "Edge", "msedge" }, new[] { "chrome", "Chrome", "chrome" }, new[] { "brave", "Brave", "brave" },
            new[] { "whale", "Whale", "whale" }, new[] { "vivaldi", "Vivaldi", "vivaldi" }, new[] { "opera", "Opera", "opera" },
            new[] { "firefox", "Firefox", "firefox" }, new[] { "308046b0af4a39cb", "Firefox", "firefox" },
        };

        /// <summary>The browser behind an SMTC app ID, or null (Pear Desktop, Spotify … are not browsers).</summary>
        public static Browser Of(string app)
        {
            if (string.IsNullOrEmpty(app)) return null;
            var id = app.ToLowerInvariant();
            foreach (var k in known) if (id.Contains(k[0])) return new Browser { Name = k[1], Process = k[2] };
            return null;
        }
    }

    /// <summary>The system media transport controls (Windows 10 1809+), read by reflection.</summary>
    internal sealed class Smtc
    {
        static readonly Type managerType = WinRt.MediaControl("GlobalSystemMediaTransportControlsSessionManager");
        static readonly Type sessionType = WinRt.MediaControl("GlobalSystemMediaTransportControlsSession");
        static readonly Type timelineType = WinRt.MediaControl("GlobalSystemMediaTransportControlsSessionTimelineProperties");
        static readonly Type playbackType = WinRt.MediaControl("GlobalSystemMediaTransportControlsSessionPlaybackInfo");
        static readonly Type propertiesType = WinRt.MediaControl("GlobalSystemMediaTransportControlsSessionMediaProperties");
        object manager;

        public static bool Available { get { return managerType != null && sessionType != null && propertiesType != null && WinRt.CanAwait; } }

        async Task<object> Manager()
        {
            if (manager == null) manager = await WinRt.Await(managerType.GetMethod("RequestAsync").Invoke(null, null), managerType);
            return manager;
        }

        /// <summary>
        /// The browser session: the one Windows shows (the media flyout's), when it is a browser's; else a browser's
        /// that is playing. Null when no browser plays anything (Pear or another player is the current session).
        /// </summary>
        async Task<object> BrowserSession()
        {
            var m = await Manager();
            var current = WinRt.Call(managerType, m, "GetCurrentSession");
            if (current != null && BrowserNames.Of(App(current)) != null) return current;
            foreach (var s in (IEnumerable)WinRt.Call(managerType, m, "GetSessions"))
                if (BrowserNames.Of(App(s)) != null && Status(s) == "Playing") return s;
            return null;
        }

        static string App(object session) { return WinRt.Get(sessionType, session, "SourceAppUserModelId") as string ?? ""; }

        static string Status(object session)
        {
            var info = WinRt.Call(sessionType, session, "GetPlaybackInfo");
            return Convert.ToString(WinRt.Get(playbackType, info, "PlaybackStatus"));
        }

        public async Task<MediaInfo> Read()
        {
            var session = await BrowserSession();
            if (session == null) return null;
            var info = new MediaInfo { App = App(session) };
            info.Browser = BrowserNames.Of(info.App);
            var playback = WinRt.Call(sessionType, session, "GetPlaybackInfo");
            info.Playing = Convert.ToString(WinRt.Get(playbackType, playback, "PlaybackStatus")) == "Playing";
            var rate = WinRt.Get(playbackType, playback, "PlaybackRate");   // IReference<double>: a boxed double or null
            if (rate is double && (double)rate > 0) info.Rate = (double)rate;
            var timeline = WinRt.Call(sessionType, session, "GetTimelineProperties");
            var start = (TimeSpan)WinRt.Get(timelineType, timeline, "StartTime");
            info.Position = ((TimeSpan)WinRt.Get(timelineType, timeline, "Position") - start).TotalSeconds;
            info.Duration = ((TimeSpan)WinRt.Get(timelineType, timeline, "EndTime") - start).TotalSeconds;
            var updated = (DateTimeOffset)WinRt.Get(timelineType, timeline, "LastUpdatedTime");
            info.Updated = updated.Year < 2000 ? DateTime.MinValue : updated.UtcDateTime;
            var props = await WinRt.Await(WinRt.Call(sessionType, session, "TryGetMediaPropertiesAsync"), propertiesType);
            if (props != null)
            {
                info.Title = WinRt.Get(propertiesType, props, "Title") as string ?? "";
                info.Artist = WinRt.Get(propertiesType, props, "Artist") as string ?? "";
                info.Album = WinRt.Get(propertiesType, props, "AlbumTitle") as string ?? "";
            }
            return info;
        }

        /// <summary>Play / pause, next, previous for the browser session.</summary>
        public async Task Control(string action)
        {
            var session = await BrowserSession();
            if (session == null) return;
            var method = action == "next" ? "TrySkipNextAsync" : action == "previous" ? "TrySkipPreviousAsync" : "TryTogglePlayPauseAsync";
            await WinRt.Await(WinRt.Call(sessionType, session, method), typeof(bool));
        }
    }

    /// <summary>
    /// A browser's windows and, through UI Automation (System.Windows.Automation, loaded at run time: Mono's reference
    /// assemblies don't have it), the address bar of a window and the titles in its tab strip. Only what is needed to
    /// name the YouTube Music video: an address is read only from a window whose title says its tab is YouTube Music.
    /// Called off the UI thread.
    /// </summary>
    internal static class BrowserWindows
    {
        internal sealed class Window { public IntPtr Handle; public string Title; }

        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

        /// <summary>The visible, titled top-level windows of a browser's processes.</summary>
        public static List<Window> Of(string process)
        {
            var pids = new HashSet<uint>();
            foreach (var p in Process.GetProcessesByName(process)) { pids.Add((uint)p.Id); p.Dispose(); }
            var found = new List<Window>();
            if (pids.Count == 0) return found;
            EnumWindows((hwnd, l) =>
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (!pids.Contains(pid) || !IsWindowVisible(hwnd)) return true;
                var sb = new StringBuilder(512);
                if (GetWindowText(hwnd, sb, sb.Capacity) > 0) found.Add(new Window { Handle = hwnd, Title = sb.ToString() });
                return true;
            }, IntPtr.Zero);
            return found;
        }

        // ---- UI Automation by reflection ----
        static readonly bool uia;
        static readonly MethodInfo fromHandle, findFirst, findAll, propertyValue;
        static readonly ConstructorInfo propertyCondition;
        static readonly object controlTypeProperty, nameProperty, valueProperty, edit, tab, tabItem, descendants, children;

        static BrowserWindows()
        {
            try
            {
                var client = Assembly.Load("UIAutomationClient, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
                var types = Assembly.Load("UIAutomationTypes, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
                var element = client.GetType("System.Windows.Automation.AutomationElement", true);
                var property = types.GetType("System.Windows.Automation.AutomationProperty", true);
                var condition = client.GetType("System.Windows.Automation.Condition", true);
                var scope = types.GetType("System.Windows.Automation.TreeScope", true);
                var controlType = types.GetType("System.Windows.Automation.ControlType", true);
                fromHandle = element.GetMethod("FromHandle", new[] { typeof(IntPtr) });
                findFirst = element.GetMethod("FindFirst", new[] { scope, condition });
                findAll = element.GetMethod("FindAll", new[] { scope, condition });
                propertyValue = element.GetMethod("GetCurrentPropertyValue", new[] { property });
                propertyCondition = client.GetType("System.Windows.Automation.PropertyCondition", true).GetConstructor(new[] { property, typeof(object) });
                controlTypeProperty = element.GetField("ControlTypeProperty").GetValue(null);
                nameProperty = element.GetField("NameProperty").GetValue(null);
                valueProperty = client.GetType("System.Windows.Automation.ValuePattern", true).GetField("ValueProperty").GetValue(null);
                edit = controlType.GetField("Edit").GetValue(null);
                tab = controlType.GetField("Tab").GetValue(null);
                tabItem = controlType.GetField("TabItem").GetValue(null);
                descendants = Enum.ToObject(scope, 4);
                children = Enum.ToObject(scope, 2);
                uia = fromHandle != null && findFirst != null && findAll != null && propertyValue != null && propertyCondition != null;
            }
            catch (Exception ex) { Log.Write("INFO UI Automation not available: " + ex.Message); }
        }

        static object Kind(object controlType) { return propertyCondition.Invoke(new[] { controlTypeProperty, controlType }); }

        /// <summary>The address bar's text: the window's first edit field (the toolbar comes before the page). Null when unreadable.</summary>
        public static string Address(IntPtr hwnd)
        {
            if (!uia) return null;
            try
            {
                var window = fromHandle.Invoke(null, new object[] { hwnd });
                var box = window == null ? null : findFirst.Invoke(window, new[] { descendants, Kind(edit) });
                return box == null ? null : propertyValue.Invoke(box, new[] { valueProperty }) as string;
            }
            catch (Exception ex) { Log.Write("INFO reading a browser's address bar failed: " + (ex.InnerException ?? ex).Message); return null; }
        }

        /// <summary>The titles in the window's tab strip (its first tab list, before any in the page).</summary>
        public static List<string> TabTitles(IntPtr hwnd)
        {
            var titles = new List<string>();
            if (!uia) return titles;
            try
            {
                var window = fromHandle.Invoke(null, new object[] { hwnd });
                var strip = window == null ? null : findFirst.Invoke(window, new[] { descendants, Kind(tab) });
                if (strip == null) return titles;
                foreach (var item in (IEnumerable)findAll.Invoke(strip, new[] { children, Kind(tabItem) }))
                {
                    var name = propertyValue.Invoke(item, new[] { nameProperty }) as string;
                    if (!string.IsNullOrEmpty(name)) titles.Add(name);
                }
            }
            catch (Exception ex) { Log.Write("INFO reading a browser's tabs failed: " + (ex.InnerException ?? ex).Message); }
            return titles;
        }
    }

    /// <summary>
    /// YouTube Music played in a web browser, as a source of songs instead of Pear Desktop: the browser hands its
    /// media session to Windows (title, artist, position, playing or paused), and the song's video comes from the tab
    /// (its address when its window shows it, else its title and a YouTube search). The song's details come from
    /// YouTube Music's queue entry for that video, so a song from the browser looks like one from Pear. Messages go
    /// out in Pear's WebSocket format. Same as macos/Sources/BrowserSource.swift, which reads macOS's now-playing
    /// information and the tabs' addresses through AppleScript instead.
    /// </summary>
    internal sealed class BrowserSource : IDisposable
    {
        internal sealed class Tab { public string Url = "", Title = ""; }

        /// <summary>A message in Pear's WebSocket format (called on the source's thread).</summary>
        public Action<IDictionary<string, object>> Message;
        /// <summary>The browser playing changed (its name, or null).</summary>
        public Action BrowserChanged;

        readonly YtmLyrics ytm;
        readonly Smtc smtc = new Smtc();
        CancellationTokenSource cts;
        MediaInfo info;
        string songKey = "", title = "", tabTitle = "";
        bool playing;
        DateTime? mismatchSince;
        Dictionary<string, object> sent;   // the song fields sent last

        public string Browser { get; private set; }
        public string VideoId { get; private set; }
        public string Playlist { get; private set; }

        public BrowserSource(YtmLyrics ytm) { this.ytm = ytm; VideoId = ""; Playlist = ""; }

        public void Start()
        {
            if (cts != null) return;
            cts = new CancellationTokenSource();
            var ct = cts.Token;
            Task.Run(() => Loop(ct));
        }

        public void Stop()
        {
            if (cts == null) return;
            cts.Cancel(); cts = null;
            songKey = ""; playing = false;
            SetBrowser(null);
        }

        public void Dispose() { Stop(); }

        /// <summary>Play / pause ("toggle-play"), "next", "previous": Windows sends them to the browser.</summary>
        public void Control(string action)
        {
            Task.Run(async () =>
            {
                try { await smtc.Control(action); }
                catch (Exception ex) { Log.Error("browser control " + action, ex); }
            });
        }

        async Task Loop(CancellationToken ct)
        {
            if (!Smtc.Available)
            {
                Log.Write("WARN the system media controls can't be read (Windows 10 1809 or later is needed); browser playback isn't shown");
                return;
            }
            while (!ct.IsCancellationRequested)
            {
                try { await Tick(ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
                catch (Exception ex) { Log.Error("browser source", ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex); }
                try { await Task.Delay(1000, ct); } catch (OperationCanceledException) { break; }
            }
        }

        async Task Tick(CancellationToken ct)
        {
            info = await smtc.Read();
            if (info == null || info.Title.Length == 0) { NotYouTubeMusic(); return; }
            var tab = FindTab(info);
            if (tab == null) { NotYouTubeMusic(); return; }   // a browser plays something, but not YouTube Music
            SetBrowser(info.Browser.Name);
            var p = WatchParameters(tab.Url);
            await Follow(p.Item1, p.Item2, TabSongTitle(tab.Title), ct);
        }

        /// <summary>Something else plays (or nothing): the browser's song, if any, stopped.</summary>
        void NotYouTubeMusic()
        {
            if (playing) { playing = false; Send(new Dictionary<string, object> { { "type", "PLAYER_STATE_CHANGED" }, { "isPlaying", false } }); }
            SetBrowser(null);
        }

        void SetBrowser(string name)
        {
            if (Browser == name) return;
            Browser = name;
            var h = BrowserChanged; if (h != null) h();
        }

        // ---- the tab ----

        string addressKey = "", address = "";
        DateTime addressChanged = DateTime.MinValue;
        string stripKey = ""; List<string> stripTitles = new List<string>();
        DateTime stripRead = DateTime.MinValue;

        /// <summary>
        /// The YouTube Music tab playing, among the browser's: a window whose title shows a YouTube Music tab gives its
        /// address (read when that title changes); tabs behind others give only their titles (read from the tab
        /// strips when the song changes, or every 10 seconds). Null when the browser has no YouTube Music tab.
        /// </summary>
        Tab FindTab(MediaInfo now)
        {
            var tabs = new List<Tab>();
            var windows = BrowserWindows.Of(now.Browser.Process);
            foreach (var w in windows.Where(w => w.Title.Contains("YouTube Music")))
            {
                // read again when the window's or Windows' title changes, and each second for 5 seconds after that
                // (the address and the title don't change at quite the same moment)
                var key = w.Handle + "|" + w.Title + "|" + now.Title;
                if (key != addressKey) { addressKey = key; addressChanged = DateTime.UtcNow; }
                if ((DateTime.UtcNow - addressChanged).TotalSeconds <= 5 || address.Length == 0) address = BrowserWindows.Address(w.Handle) ?? "";
                tabs.Add(new Tab { Url = address.Contains("music.youtube.com") ? address : "", Title = w.Title });
            }
            var wanted = now.Title + "|" + string.Join("|", windows.Select(w => w.Handle.ToString()));
            if (wanted != stripKey || (DateTime.UtcNow - stripRead).TotalSeconds >= 10)
            {
                stripKey = wanted; stripRead = DateTime.UtcNow;
                stripTitles = windows.SelectMany(w => BrowserWindows.TabTitles(w.Handle)).Where(t => t.Contains("YouTube Music")).ToList();
            }
            foreach (var t in stripTitles)
                if (!tabs.Any(x => TabSongTitle(x.Title) == TabSongTitle(t))) tabs.Add(new Tab { Title = t });
            return PlayingTab(tabs, now.Title);
        }

        /// <summary>The tab named like what Windows reports; else the only video tab, or the only YouTube Music tab.</summary>
        internal static Tab PlayingTab(List<Tab> tabs, string title)
        {
            var named = tabs.FirstOrDefault(t => SameSong(title, TabSongTitle(t.Title), ""));
            if (named != null) return named;
            var videos = tabs.Where(t => WatchParameters(t.Url).Item1.Length > 0).ToList();
            if (videos.Count == 1) return videos[0];
            return tabs.Count == 1 ? tabs[0] : null;
        }

        /// <summary>"アイドル - Idol | YouTube Music - Google Chrome" -> "アイドル - Idol" ("" for "YouTube Music" alone).</summary>
        internal static string TabSongTitle(string title)
        {
            if (string.IsNullOrEmpty(title)) return "";
            int at = title.IndexOf(" | YouTube Music", StringComparison.Ordinal);
            if (at < 0) at = title.IndexOf(" - YouTube Music", StringComparison.Ordinal);
            return at >= 0 ? title.Substring(0, at).Trim() : "";
        }

        /// <summary>The video ID and playlist of a music.youtube.com/watch address (the address bar may leave out "https://").</summary>
        internal static Tuple<string, string> WatchParameters(string url)
        {
            var none = Tuple.Create("", "");
            if (string.IsNullOrEmpty(url)) return none;
            if (!url.Contains("://")) url = "https://" + url;
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Host != "music.youtube.com" || uri.AbsolutePath != "/watch") return none;
            string v = "", list = "";
            foreach (var part in uri.Query.TrimStart('?').Split('&'))
            {
                int eq = part.IndexOf('=');
                if (eq <= 0) continue;
                var name = part.Substring(0, eq);
                var value = Uri.UnescapeDataString(part.Substring(eq + 1));
                if (name == "v") v = value; else if (name == "list") list = value;
            }
            return Tuple.Create(YtmLyrics.IsVideoId(v) ? v : "", list);
        }

        // ---- the song ----

        /// <summary>
        /// The song playing: a new one is looked up and announced (VIDEO_CHANGED); the same one gets its position and
        /// play state. <paramref name="urlId"/> empty: the tab's address isn't known, only titles.
        /// </summary>
        async Task Follow(string urlId, string list, string tabSong, CancellationToken ct)
        {
            var id = urlId;
            // The tab's title and Windows' should name the same song. They don't for a moment while a song changes;
            // and a tab can keep another song's address and title while it plays this one (seen on macOS 2026-10-20).
            // Then a song with an album is YouTube Music's, found by title; without one, it's another site playing.
            if (tabSong.Length > 0 && !SameSong(info.Title, tabSong, ""))
            {
                if (!Mismatched()) { TickPosition(); return; }
                if (info.Album.Length == 0) { NotYouTubeMusic(); return; }
                id = ""; tabSong = "";
            }
            var key = id.Length > 0 ? id : "|" + info.Title + "|" + info.Artist;
            if (key == songKey) { mismatchSince = null; Playlist = list; TickPosition(); return; }
            // the address names another song than the one playing (read before it changed): wait for it, then go by title
            if (id.Length > 0 && !await AddressNamesSong(id, tabSong, ct))
            {
                if (!Mismatched()) { TickPosition(); return; }
                id = ""; key = "|" + info.Title + "|" + info.Artist;
                if (key == songKey) { TickPosition(); return; }
            }
            mismatchSince = null;

            var found = id;
            if (found.Length == 0) found = await VideoByTitle(info, tabSong, list, urlId, ct);
            var song = await SongFor(found, id.Length > 0 ? tabSong : "", info, ct);
            NoteGuess(list, found);
            songKey = key; VideoId = found; Playlist = list; title = song["title"] as string ?? ""; sent = song;
            tabTitle = id.Length > 0 ? tabSong : "";
            // Windows may still describe the song before for a moment: its position only when it names this one
            double position = SameSong(info.Title, title, tabTitle) ? info.PositionAt(DateTime.UtcNow) : 0;
            playing = info.Playing;
            Log.Info("browser (" + Browser + ") plays " + (found.Length > 0 ? found : "a song without a known video") + ": " + song["artist"] + " - " + title);
            Send(new Dictionary<string, object> { { "type", "VIDEO_CHANGED" }, { "song", song }, { "isPlaying", info.Playing }, { "position", position } });
        }

        /// <summary>Whether titles have disagreed for 3 seconds now (started on the first call).</summary>
        bool Mismatched()
        {
            if (mismatchSince == null) mismatchSince = DateTime.UtcNow;
            return (DateTime.UtcNow - mismatchSince.Value).TotalSeconds >= 3;
        }

        /// <summary>Whether YouTube Music's title for the address's video is the song Windows (or the tab) names.</summary>
        async Task<bool> AddressNamesSong(string id, string tabSong, CancellationToken ct)
        {
            try
            {
                var track = await ytm.Lookup(id, ct, false);
                return track.Title.Length == 0 || SameSong(info.Title, track.Title, "") || (tabSong.Length > 0 && SameSong(tabSong, track.Title, "") && SameSong(info.Title, tabSong, ""));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { return true; }   // can't tell; the details fall back to Windows' own
        }

        /// <summary>The position and play state of the song sent last, from what Windows reports now.</summary>
        void TickPosition()
        {
            if (songKey.Length == 0 || !SameSong(info.Title, title, tabTitle)) return;
            double position = info.PositionAt(DateTime.UtcNow);
            // the album, once Windows describes this song (it was still on the song before when this one was sent)
            if (sent != null && (sent["album"] as string ?? "").Length == 0 && info.Album.Length > 0)
            {
                sent["album"] = info.Album; playing = info.Playing;
                Send(new Dictionary<string, object> { { "type", "VIDEO_CHANGED" }, { "song", sent }, { "isPlaying", playing }, { "position", position } });
                return;
            }
            if (info.Playing != playing)
            {
                playing = info.Playing;
                Send(new Dictionary<string, object> { { "type", "PLAYER_STATE_CHANGED" }, { "isPlaying", playing }, { "position", position } });
            }
            else if (playing) Send(new Dictionary<string, object> { { "type", "POSITION_CHANGED" }, { "position", position } });
        }

        /// <summary>Whether Windows' title is this song's: the same, or one half of "original - translation".</summary>
        internal static bool SameSong(string reported, string title, string tabSong)
        {
            var r = CoverLyrics.Norm(reported);
            if (r.Length == 0) return false;
            foreach (var candidate in new[] { title, tabSong })
            {
                if (string.IsNullOrEmpty(candidate)) continue;
                var c = CoverLyrics.Norm(candidate);
                if (c.Length > 0 && (c == r || c.Contains(r) || r.Contains(c))) return true;
            }
            return false;
        }

        /// <summary>
        /// The video of a song known by its titles, artist and length: an entry of the tab's playlist with that title
        /// and length, or YouTube's search (with the tab's title when it has one: it carries the original title,
        /// "アイドル - Idol", where Windows has only the player's language, "Idol"). "" when neither is sure.
        /// </summary>
        async Task<string> VideoByTitle(MediaInfo now, string tabSong, string list, string near, CancellationToken ct)
        {
            try
            {
                if (list.Length > 0 && near.Length > 0)
                {
                    var entry = (await ytm.PlaylistEntries(near, list, ct)).FirstOrDefault(e =>
                        SameSong(now.Title, e.Title, "") && (now.Duration <= 0 || Math.Abs(e.Duration - now.Duration) <= 3));
                    if (entry != null) return entry.VideoId;
                }
                return await ytm.FindVideo(tabSong.Length > 0 ? tabSong : now.Title, now.Artist, now.Duration, ct) ?? "";
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex) { Log.Write("INFO YouTube search failed: " + ex.Message); return ""; }
        }

        /// <summary>
        /// Pear's song fields for this video: YouTube Music's queue entry (title, artist, length, kind, cover), with
        /// Windows' title when it is one half of the entry's ("Idol" of "アイドル - Idol", as Pear gives it).
        /// </summary>
        async Task<Dictionary<string, object>> SongFor(string id, string tabSong, MediaInfo now, CancellationToken ct)
        {
            var song = new Dictionary<string, object>
            {
                { "title", now.Title }, { "artist", now.Artist }, { "album", now.Album }, { "songDuration", now.Duration },
                { "videoId", id }, { "mediaType", id.Length == 0 ? "UNKNOWN" : "" },
            };
            if (id.Length == 0) return song;
            try
            {
                var track = await ytm.Lookup(id, ct, false);
                bool described = SameSong(now.Title, track.Title, "");
                if (track.Title.Length > 0) song["title"] = described ? now.Title : track.Title;
                // Windows may still describe the song before (its album would stay on this one); TickPosition fills it in later
                if (!described) song["album"] = "";
                if (track.Artist.Length > 0) song["artist"] = track.Artist;
                if (track.Duration > 0) song["songDuration"] = track.Duration;
                song["mediaType"] = MediaType(track.VideoType);
                if (track.Thumbnail.Length > 0) song["imageSrc"] = track.Thumbnail;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Write("INFO YouTube Music details for " + id + " failed (" + ex.Message + "); using what Windows reports");
                if (now.Title.Length == 0 && tabSong.Length > 0) song["title"] = tabSong;
            }
            return song;
        }

        /// <summary>Pear's MediaType for YouTube Music's musicVideoType.</summary>
        internal static string MediaType(string videoType)
        {
            switch (videoType)
            {
                case "MUSIC_VIDEO_TYPE_ATV": return "AUDIO";
                case "MUSIC_VIDEO_TYPE_OMV": return "ORIGINAL_MUSIC_VIDEO";
                case "MUSIC_VIDEO_TYPE_UGC": return "USER_GENERATED_CONTENT";
                case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": return "PODCAST_EPISODE";
                case "": return "";
                default: return "OTHER_VIDEO";
            }
        }

        // ---- the next song ----

        readonly Dictionary<string, string> guesses = new Dictionary<string, string>();
        readonly HashSet<string> missed = new HashSet<string>();

        /// <summary>
        /// The next song, guessed from the tab's playlist (an album or a playlist, in order). The browser's own queue
        /// can't be read, so with shuffle (or a radio, made for the signed-in user) the guess is wrong: after a wrong
        /// guess for a playlist, the guess is still made (one YouTube Music request) but not handed out until one comes
        /// true again, so no lyrics are fetched ahead for songs that won't play. Null without a playlist.
        /// </summary>
        public async Task<SongInfo> NextSong(CancellationToken ct)
        {
            string id = VideoId, list = Playlist;
            if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(list)) return null;
            var next = await ytm.QueueAfter(id, list, ct);
            if (next == null || next.VideoId.Length == 0) return null;
            lock (guesses)
            {
                guesses[list] = next.VideoId;
                if (missed.Contains(list)) return null;
            }
            return new SongInfo { Title = next.Title, Artist = next.Artist, VideoId = next.VideoId, MediaType = MediaType(next.VideoType), Duration = next.Duration };
        }

        /// <summary>A new song from <paramref name="list"/>: was it the one guessed?</summary>
        void NoteGuess(string list, string id)
        {
            if (list.Length == 0) return;
            lock (guesses)
            {
                string guess;
                if (!guesses.TryGetValue(list, out guess)) return;
                guesses.Remove(list);
                if (guess == id) missed.Remove(list);
                else if (missed.Add(list)) Log.Info("the browser didn't play the next song of its playlist (shuffle?); not fetching ahead for it");
            }
        }

        void Send(IDictionary<string, object> message)
        {
            var h = Message; if (h != null) h(message);
        }
    }
}

namespace PearNowPlaying
{
    /// <summary>
    /// "NowPlayingWidget.exe --browser-probe [seconds]": what the browser source sees and sends, once a second, for trying
    /// it against a real browser. Written to the console it was started from and to browser-probe.log next to the log.
    /// </summary>
    internal static class BrowserProbe
    {
        [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

        public static void Run(double seconds)
        {
            AttachConsole(-1);
            var file = System.IO.Path.Combine(Config.Dir, "browser-probe.log");
            System.IO.Directory.CreateDirectory(Config.Dir);
            var gate = new object();
            Action<string> line = text =>
            {
                var stamped = DateTime.Now.ToString("HH:mm:ss.f") + " " + text;
                lock (gate)
                {
                    Console.WriteLine(stamped);
                    try { System.IO.File.AppendAllText(file, stamped + Environment.NewLine, Encoding.UTF8); } catch { }
                }
            };
            line("browser probe " + AppInfo.Version + " for " + seconds + " s; SMTC " + (Smtc.Available ? "available" : "NOT available"));
            var ytm = new YtmLyrics();
            var source = new BrowserSource(ytm);
            var json = new System.Web.Script.Serialization.JavaScriptSerializer();
            source.Message = m => line("send " + json.Serialize(m));
            source.BrowserChanged = () => line("browser: " + (source.Browser ?? "none"));
            source.Start();
            var smtc = new Smtc();
            var seenWindows = new HashSet<string>();
            var until = DateTime.UtcNow.AddSeconds(seconds);
            bool askedNext = false;
            while (DateTime.UtcNow < until)
            {
                try
                {
                    var info = smtc.Read().GetAwaiter().GetResult();
                    if (info == null) line("smtc: no browser session");
                    else
                    {
                        line("smtc: " + info.App + " " + (info.Playing ? "playing" : "paused") + " " + info.PositionAt(DateTime.UtcNow).ToString("0.0")
                             + "/" + info.Duration.ToString("0") + " (reported " + info.Position.ToString("0.0") + " at " + info.Updated.ToLocalTime().ToString("HH:mm:ss.f")
                             + ", rate " + info.Rate + ") " + info.Artist + " - " + info.Title + " [" + info.Album + "]");
                        foreach (var w in BrowserWindows.Of(info.Browser.Process))
                        {
                            if (!seenWindows.Add(w.Handle + "|" + w.Title)) continue;
                            line("window " + w.Handle + ": " + w.Title);
                            if (w.Title.Contains("YouTube Music")) line("  address: " + (BrowserWindows.Address(w.Handle) ?? "(unreadable)"));
                            foreach (var t in BrowserWindows.TabTitles(w.Handle)) line("  tab: " + t);
                        }
                    }
                    if (!askedNext && DateTime.UtcNow > until.AddSeconds(-seconds + 15))
                    {
                        askedNext = true;
                        var next = source.NextSong(CancellationToken.None).GetAwaiter().GetResult();
                        line("playing " + source.VideoId + " in " + (source.Playlist.Length > 0 ? source.Playlist : "no playlist") + "; next: "
                             + (next == null ? "none" : next.VideoId + " " + next.Artist + " - " + next.Title + " [" + next.MediaType + "]"));
                    }
                }
                catch (Exception ex) { line("error: " + ex); }
                Thread.Sleep(1000);
            }
            source.Stop();
            line("done; also in " + file);
        }
    }
}
