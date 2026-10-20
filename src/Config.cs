using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace PearNowPlaying
{
    /// <summary>Custom: where the user dragged the widget (CustomX / CustomY / CustomFromBottom).</summary>
    internal enum OverlayPosition { TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight, Custom }

    /// <summary>
    /// One widget: the monitor it is on and where on that monitor ("widget2=BottomLeft" in config.ini, the number
    /// being the menu's "모니터 2"). Custom: where the user dragged it, in px from the monitor's left edge and from
    /// its top or bottom edge ("widget1=Custom 120 80 bottom"). Each widget has its own size and transparency
    /// ("widget1Scale=1.25", "widget1Transparency=0.3").
    /// </summary>
    internal sealed class WidgetPlace
    {
        public int Monitor;
        public OverlayPosition Position = OverlayPosition.BottomLeft;
        public int CustomX = 40, CustomY = 140;
        public bool CustomFromBottom = true;
        /// <summary>Size (1.0 = normal).</summary>
        public double Scale = 1.0;
        /// <summary>How see-through the whole widget is, text included (0 = not at all).</summary>
        public double Transparency;
        /// <summary>Turned off in the 표시 menu: kept with its settings so turning it on again brings them back.</summary>
        public bool Hidden;

        /// <summary>The same widget on another monitor (a new widget starts like the first one).</summary>
        public WidgetPlace CopyTo(int monitor)
        {
            return new WidgetPlace { Monitor = monitor, Position = Position, CustomX = CustomX, CustomY = CustomY,
                                     CustomFromBottom = CustomFromBottom, Scale = Scale, Transparency = Transparency };
        }

        public string Spec()
        {
            return Position == OverlayPosition.Custom
                ? "Custom " + CustomX.ToString(CultureInfo.InvariantCulture) + " " + CustomY.ToString(CultureInfo.InvariantCulture) + " " + (CustomFromBottom ? "bottom" : "top")
                : Position.ToString();
        }

        /// <summary>"BottomLeft" / "Custom 120 80 bottom"; null when it can't be read.</summary>
        public static WidgetPlace Parse(int monitor, string spec)
        {
            var parts = (spec ?? "").Split(new[] { ' ', '\t', ',' }, StringSplitOptions.RemoveEmptyEntries);
            OverlayPosition pos;
            if (parts.Length == 0 || !Enum.TryParse(parts[0], true, out pos) || !Enum.IsDefined(typeof(OverlayPosition), pos)) return null;
            var w = new WidgetPlace { Monitor = monitor, Position = pos };
            if (pos == OverlayPosition.Custom)
            {
                int x, y;
                if (parts.Length < 3 || !int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out x)
                    || !int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out y)) return null;
                w.CustomX = Math.Max(0, x); w.CustomY = Math.Max(0, y);
                w.CustomFromBottom = parts.Length < 4 || !parts[3].Equals("top", StringComparison.OrdinalIgnoreCase);
            }
            return w;
        }
    }

    internal sealed class Config
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PearNowPlaying");
        public static string FilePath { get { return Path.Combine(Dir, "config.ini"); } }
        public static string TokenPath { get { return Path.Combine(Dir, "token.txt"); } }
        public static string LogPath { get { return Path.Combine(Dir, "error.log"); } }

        /// <summary>Where songs come from: "auto" (a web browser and Pear Desktop, whichever started playing last),
        /// "browser" (YouTube Music in a web browser only) or "pear" (Pear Desktop only).</summary>
        public string Source = "auto";

        // Pear Desktop API server
        public string Host = "127.0.0.1";
        public int Port = 26538;
        public bool Https = false;

        // Overlay
        /// <summary>The widgets, one per monitor (at least one).</summary>
        public List<WidgetPlace> Widgets = new List<WidgetPlace> { new WidgetPlace() };

        /// <summary>The widgets turned on in the 표시 menu (at least one).</summary>
        public List<WidgetPlace> OnWidgets { get { return Widgets.Where(w => !w.Hidden).ToList(); } }
        public int MarginX = 40;
        public int MarginY = 140;
        public double Scale = 1.0;
        public int PanelWidth = 420;
        public double ShowSeconds = 6;
        public double Opacity = 0.92;
        public bool AlwaysShow = true;
        public bool ShowOnPause = true;
        public bool ShowAlbumArt = true;
        /// <summary>Title shown for videos (not album tracks): false = the song title (Pear's title),
        /// true = the video's own title (Pear's alternativeTitle, what Pear's Discord status shows).</summary>
        public bool VideoTitle = false;

        /// <summary>Show the browser's song as "Listening to" on Discord (off unless the user turns it on).</summary>
        public bool DiscordPresence = false;
        /// <summary>Put a button to the project's GitHub page in that Discord status.</summary>
        public bool DiscordButton = true;

        // Lyrics
        public bool ShowLyrics = true;
        /// <summary>Lyrics only for album tracks (Pear's AUDIO); other songs aren't even looked up.</summary>
        public bool LyricsAlbumOnly = false;
        /// <summary>Look for a new release on GitHub at start and once a day (installing is always the user's choice).</summary>
        public bool CheckUpdates = true;
        public bool LyricsShowNext = true;
        public int LyricsOffsetMs = 300;
        public string LyricsServer = "https://lrclib.net";
        public bool YtmLyrics = true;
        public string YtmLyricsProxy = PearNowPlaying.YtmLyrics.DefaultProxy;
        /// <summary>Ask Kugou and NetEase when LRCLIB has no synced lyrics.</summary>
        public bool MoreLyrics = true;

        // Hotkeys ("없음" or empty = disabled)
        public string HotkeyLyrics = "Ctrl+Alt+L";
        public string HotkeyShow = "Ctrl+Alt+Up";
        public string HotkeyToggle = "Ctrl+Alt+Down";
        public string HotkeyNext = "Ctrl+Alt+Right";
        public string HotkeyPrevious = "Ctrl+Alt+Left";
        public string HotkeyAlwaysShow = "Ctrl+Alt+P";

        public static Config Load()
        {
            var c = new Config();
            try
            {
                Directory.CreateDirectory(Dir);
                MigrateOldConfig();
                if (!File.Exists(FilePath)) { c.Save(); return c; }
                var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var raw in File.ReadAllLines(FilePath, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";")) continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    map[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                c.Host = Get(map, "host", c.Host);
                c.Port = GetInt(map, "port", c.Port);
                c.Https = GetBool(map, "https", c.Https);
                // widgets: "widget1=BottomLeft", "widget2=Custom 120 80 bottom" (numbers as in the menu, from 1)
                var widgets = new List<WidgetPlace>();
                foreach (var kv in map)
                {
                    int n;
                    if (!kv.Key.StartsWith("widget", StringComparison.OrdinalIgnoreCase)
                        || !int.TryParse(kv.Key.Substring(6), NumberStyles.None, CultureInfo.InvariantCulture, out n) || n < 1) continue;
                    var w = WidgetPlace.Parse(n - 1, kv.Value);
                    if (w != null && widgets.All(o => o.Monitor != w.Monitor)) widgets.Add(w);
                }
                if (widgets.Count == 0)
                {
                    // 1.6 and older: one widget, "monitor" (from 0) + "position" (+ customX/Y/FromBottom)
                    var w = new WidgetPlace { Monitor = Math.Max(0, GetInt(map, "monitor", 0)) };
                    OverlayPosition pos;
                    if (Enum.TryParse(Get(map, "position", "BottomLeft"), true, out pos) && Enum.IsDefined(typeof(OverlayPosition), pos)) w.Position = pos;
                    w.CustomX = Math.Max(0, GetInt(map, "customX", w.CustomX));
                    w.CustomY = Math.Max(0, GetInt(map, "customY", w.CustomY));
                    w.CustomFromBottom = GetBool(map, "customFromBottom", w.CustomFromBottom);
                    widgets.Add(w);
                }
                c.Widgets = widgets.OrderBy(w => w.Monitor).ToList();
                c.Source = Get(map, "source", c.Source).ToLowerInvariant();
                if (c.Source != "browser" && c.Source != "pear") c.Source = "auto";
                c.MarginX = GetInt(map, "marginX", c.MarginX);
                c.MarginY = GetInt(map, "marginY", c.MarginY);
                c.Scale = Clamp(GetDouble(map, "scale", c.Scale), 0.5, 3.0);
                // per widget; 1.7 and older had one "scale" for all, which each widget starts from
                foreach (var w in c.Widgets)
                {
                    var n = "widget" + (w.Monitor + 1).ToString(CultureInfo.InvariantCulture);
                    w.Scale = Clamp(GetDouble(map, n + "Scale", c.Scale), 0.5, 3.0);
                    w.Transparency = Clamp(GetDouble(map, n + "Transparency", 0), 0, 0.8);
                    w.Hidden = !GetBool(map, n + "Show", true);
                }
                if (c.Widgets.All(w => w.Hidden)) c.Widgets[0].Hidden = false;   // at least one widget stays on
                c.PanelWidth = Math.Max(260, Math.Min(1200, GetInt(map, "panelWidth", c.PanelWidth)));
                c.ShowSeconds = Clamp(GetDouble(map, "showSeconds", c.ShowSeconds), 1, 60);
                c.Opacity = Clamp(GetDouble(map, "opacity", c.Opacity), 0.2, 1.0);
                c.AlwaysShow = GetBool(map, "alwaysShow", c.AlwaysShow);
                c.ShowOnPause = GetBool(map, "showOnPause", c.ShowOnPause);
                c.ShowAlbumArt = GetBool(map, "showAlbumArt", c.ShowAlbumArt);
                c.VideoTitle = GetBool(map, "videoTitle", c.VideoTitle);
                c.DiscordPresence = GetBool(map, "discordPresence", c.DiscordPresence);
                c.DiscordButton = GetBool(map, "discordButton", c.DiscordButton);
                c.ShowLyrics = GetBool(map, "showLyrics", c.ShowLyrics);
                c.LyricsAlbumOnly = GetBool(map, "lyricsAlbumOnly", c.LyricsAlbumOnly);
                c.CheckUpdates = GetBool(map, "checkUpdates", c.CheckUpdates);
                c.LyricsShowNext = GetBool(map, "lyricsShowNext", c.LyricsShowNext);
                c.LyricsOffsetMs = Math.Max(-10000, Math.Min(10000, GetInt(map, "lyricsOffsetMs", c.LyricsOffsetMs)));
                c.LyricsServer = Get(map, "lyricsServer", c.LyricsServer);
                c.YtmLyrics = GetBool(map, "ytmLyrics", c.YtmLyrics);
                c.YtmLyricsProxy = Get(map, "ytmLyricsProxy", c.YtmLyricsProxy);
                c.MoreLyrics = GetBool(map, "moreLyrics", c.MoreLyrics);
                c.HotkeyLyrics = Get(map, "hotkeyLyrics", c.HotkeyLyrics);
                c.HotkeyShow = Get(map, "hotkeyShow", c.HotkeyShow);
                c.HotkeyToggle = Get(map, "hotkeyToggle", c.HotkeyToggle);
                c.HotkeyNext = Get(map, "hotkeyNext", c.HotkeyNext);
                c.HotkeyPrevious = Get(map, "hotkeyPrevious", c.HotkeyPrevious);
                c.HotkeyAlwaysShow = Get(map, "hotkeyAlwaysShow", c.HotkeyAlwaysShow);
            }
            catch (Exception ex) { Log.Error("config load", ex); }
            return c;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var inv = CultureInfo.InvariantCulture;
                var sb = new StringBuilder();
                sb.AppendLine("# Pear Now Playing 설정 파일");
                sb.AppendLine("# 수정한 뒤 트레이 메뉴의 '설정 다시 불러오기'를 누르면 적용됩니다.");
                sb.AppendLine();
                sb.AppendLine("# 곡을 가져올 곳: auto(브라우저와 Pear Desktop 중 나중에 재생을 시작한 쪽), browser(브라우저의 YouTube Music만), pear(Pear Desktop만)");
                sb.AppendLine("source=" + Source);
                sb.AppendLine();
                sb.AppendLine("# Pear Desktop > 플러그인 > API 서버 의 호스트/포트와 같아야 합니다.");
                sb.AppendLine("host=" + Host);
                sb.AppendLine("port=" + Port.ToString(inv));
                sb.AppendLine("https=" + B(Https));
                sb.AppendLine();
                sb.AppendLine("# 위젯을 띄울 모니터와 위치. 'widget' 뒤의 숫자는 메뉴의 '모니터 1', '모니터 2'와 같은 번호입니다.");
                sb.AppendLine("# 위치: TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight,");
                sb.AppendLine("#       또는 Custom x y bottom|top (트레이 메뉴의 '위젯 끌어서 옮기기'로 놓은 위치, 모니터 왼쪽과 아래/위 가장자리에서 떨어진 px)");
                foreach (var w in Widgets) sb.AppendLine("widget" + (w.Monitor + 1).ToString(inv) + "=" + w.Spec());
                sb.AppendLine("# 위젯마다 표시 여부(false면 꺼 두고 설정만 보관), 크기 배율(1.0 = 기본), 투명도(0 = 불투명, 최대 0.8, 글자까지 함께 투명해짐)");
                foreach (var w in Widgets)
                {
                    var n = "widget" + (w.Monitor + 1).ToString(inv);
                    sb.AppendLine(n + "Show=" + B(!w.Hidden));
                    sb.AppendLine(n + "Scale=" + w.Scale.ToString("0.##", inv));
                    sb.AppendLine(n + "Transparency=" + w.Transparency.ToString("0.##", inv));
                }
                sb.AppendLine("# 화면 가장자리로부터의 여백(px, Custom이 아닌 위치에 적용)");
                sb.AppendLine("marginX=" + MarginX.ToString(inv));
                sb.AppendLine("marginY=" + MarginY.ToString(inv));
                sb.AppendLine("# 크기 배율 (1.0 = 기본). 위의 widgetNScale이 없는 위젯에 적용됩니다.");
                sb.AppendLine("scale=" + Scale.ToString("0.##", inv));
                sb.AppendLine("# 곡 카드와 가사 카드의 너비(px, 배율 적용 전)");
                sb.AppendLine("panelWidth=" + PanelWidth.ToString(inv));
                sb.AppendLine("# 곡이 바뀌었을 때 표시하는 시간(초)");
                sb.AppendLine("showSeconds=" + ShowSeconds.ToString("0.##", inv));
                sb.AppendLine("# 카드 배경의 불투명도 (0.2 ~ 1.0, 글자는 그대로)");
                sb.AppendLine("opacity=" + Opacity.ToString("0.##", inv));
                sb.AppendLine("# true면 사라지지 않고 계속 표시");
                sb.AppendLine("alwaysShow=" + B(AlwaysShow));
                sb.AppendLine("# 일시정지/재생 시에도 잠깐 표시");
                sb.AppendLine("showOnPause=" + B(ShowOnPause));
                sb.AppendLine("showAlbumArt=" + B(ShowAlbumArt));
                sb.AppendLine("# 영상(MV·커버 등, 앨범 곡 제외)에 영상 제목을 표시 (false면 곡 제목, true면 Pear의 Discord 상태와 같은 영상 제목)");
                sb.AppendLine("videoTitle=" + B(VideoTitle));
                sb.AppendLine("# 브라우저에서 듣는 곡을 Discord 프로필에 '듣는 중'으로 표시 (Pear Desktop의 곡은 표시하지 않습니다)");
                sb.AppendLine("discordPresence=" + B(DiscordPresence));
                sb.AppendLine("# Discord의 '듣는 중'에 이 앱의 GitHub 페이지로 가는 버튼을 붙임");
                sb.AppendLine("discordButton=" + B(DiscordButton));
                sb.AppendLine();
                sb.AppendLine("# 가사 (LRCLIB 싱크 가사가 있는 곡만 표시)");
                sb.AppendLine("showLyrics=" + B(ShowLyrics));
                sb.AppendLine("# true면 앨범 곡(공식 음원)에서만 가사를 찾아 표시 (MV·커버 등은 찾지 않음)");
                sb.AppendLine("lyricsAlbumOnly=" + B(LyricsAlbumOnly));
                sb.AppendLine("# 다음 줄 가사도 작게 표시");
                sb.AppendLine("lyricsShowNext=" + B(LyricsShowNext));
                sb.AppendLine("# 가사 타이밍 보정(ms). +면 가사가 더 빨리, -면 더 늦게 나옵니다.");
                sb.AppendLine("lyricsOffsetMs=" + LyricsOffsetMs.ToString(inv));
                sb.AppendLine("lyricsServer=" + LyricsServer);
                sb.AppendLine("# YouTube Music 가사를 먼저 찾고, 실패하면 LRCLIB로 찾기 (Pear Desktop의 YTMusic 가사 제공자와 같은 방식). 메뉴에는 없는 설정입니다.");
                sb.AppendLine("ytmLyrics=" + B(YtmLyrics));
                sb.AppendLine("# YouTube Music 가사 중계 서버 (Pear Desktop이 쓰는 외부 서버)");
                sb.AppendLine("ytmLyricsProxy=" + YtmLyricsProxy);
                sb.AppendLine("# LRCLIB에 싱크 가사가 없으면 Kugou와 NetEase(网易云音乐)에서도 찾기. 메뉴에는 없는 설정입니다.");
                sb.AppendLine("moreLyrics=" + B(MoreLyrics));
                sb.AppendLine();
                sb.AppendLine("# 새 버전이 있는지 GitHub에서 확인 (켜 두면 시작할 때와 하루에 한 번, 설치는 메뉴에서 직접 누를 때만 함)");
                sb.AppendLine("checkUpdates=" + B(CheckUpdates));
                sb.AppendLine();
                sb.AppendLine("# 단축키 (예: Ctrl+Alt+Right, Ctrl+Shift+F9, 비워두면 사용 안 함)");
                sb.AppendLine("hotkeyShow=" + HotkeyShow);
                sb.AppendLine("hotkeyToggle=" + HotkeyToggle);
                sb.AppendLine("hotkeyNext=" + HotkeyNext);
                sb.AppendLine("hotkeyPrevious=" + HotkeyPrevious);
                sb.AppendLine("hotkeyAlwaysShow=" + HotkeyAlwaysShow);
                sb.AppendLine("hotkeyLyrics=" + HotkeyLyrics);
                File.WriteAllText(FilePath, sb.ToString(), new UTF8Encoding(true));
            }
            catch (Exception ex) { Log.Error("config save", ex); }
        }

        public string BaseHttp { get { return (Https ? "https://" : "http://") + Host + ":" + Port; } }
        public string BaseWs { get { return (Https ? "wss://" : "ws://") + Host + ":" + Port; } }

        public static string ReadToken()
        {
            try { return File.Exists(TokenPath) ? File.ReadAllText(TokenPath).Trim() : null; }
            catch { return null; }
        }

        public static void WriteToken(string token)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                if (string.IsNullOrEmpty(token)) { if (File.Exists(TokenPath)) File.Delete(TokenPath); }
                else File.WriteAllText(TokenPath, token);
            }
            catch (Exception ex) { Log.Error("token save", ex); }
        }

        /// <summary>Carry config.ini over from the app's previous name (ETS2 Now Playing), once.</summary>
        static void MigrateOldConfig()
        {
            try
            {
                if (File.Exists(FilePath)) return;
                var old = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "ETS2NowPlaying", "config.ini");
                if (!File.Exists(old)) return;
                var text = File.ReadAllText(old, Encoding.UTF8).Replace("ETS2 Now Playing", "Pear Now Playing");
                File.WriteAllText(FilePath, text, new UTF8Encoding(true));
                Log.Info("migrated config from " + old);
            }
            catch (Exception ex) { Log.Error("config migrate", ex); }
        }

        static string B(bool v) { return v ? "true" : "false"; }
        static double Clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
        static string Get(Dictionary<string, string> m, string k, string d) { string v; return m.TryGetValue(k, out v) ? v : d; }
        static int GetInt(Dictionary<string, string> m, string k, int d)
        {
            int v; return int.TryParse(Get(m, k, ""), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : d;
        }
        static double GetDouble(Dictionary<string, string> m, string k, double d)
        {
            double v; return double.TryParse(Get(m, k, ""), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : d;
        }
        static bool GetBool(Dictionary<string, string> m, string k, bool d)
        {
            var s = Get(m, k, "").ToLowerInvariant();
            if (s == "true" || s == "1" || s == "yes" || s == "on") return true;
            if (s == "false" || s == "0" || s == "no" || s == "off") return false;
            return d;
        }
    }

    internal static class Log
    {
        static readonly object Gate = new object();
        public static void Error(string where, Exception ex) { Write("ERROR " + where + ": " + ex); }
        public static void Info(string msg) { Write("INFO " + msg); }
        public static void Write(string msg)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Config.Dir);
                    var fi = new FileInfo(Config.LogPath);
                    if (fi.Exists && fi.Length > 512 * 1024) fi.Delete();
                    File.AppendAllText(Config.LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + msg + Environment.NewLine);
                }
            }
            catch { }
        }
    }
}
