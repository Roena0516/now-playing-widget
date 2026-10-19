using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace PearNowPlaying
{
    /// <summary>Custom: where the user dragged the widget (CustomX / CustomY / CustomFromBottom).</summary>
    internal enum OverlayPosition { TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight, Custom }

    internal sealed class Config
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PearNowPlaying");
        public static string FilePath { get { return Path.Combine(Dir, "config.ini"); } }
        public static string TokenPath { get { return Path.Combine(Dir, "token.txt"); } }
        public static string LogPath { get { return Path.Combine(Dir, "error.log"); } }

        // Pear Desktop API server
        public string Host = "127.0.0.1";
        public int Port = 26538;
        public bool Https = false;

        // Overlay
        public OverlayPosition Position = OverlayPosition.BottomLeft;
        public int MarginX = 40;
        public int MarginY = 140;
        public double Scale = 1.0;
        public int PanelWidth = 420;
        public int Monitor = 0;
        // Custom position (px on the monitor, no DPI scaling): from the left edge, and from the top or bottom edge
        public int CustomX = 40;
        public int CustomY = 140;
        public bool CustomFromBottom = true;
        public double ShowSeconds = 6;
        public double Opacity = 0.92;
        public bool AlwaysShow = true;
        public bool ShowOnPause = true;
        public bool ShowAlbumArt = true;
        /// <summary>Title shown for videos (not album tracks): false = the song title (Pear's title),
        /// true = the video's own title (Pear's alternativeTitle, what Pear's Discord status shows).</summary>
        public bool VideoTitle = false;

        // Lyrics
        public bool ShowLyrics = true;
        public bool LyricsShowNext = true;
        public int LyricsOffsetMs = 300;
        public string LyricsServer = "https://lrclib.net";
        public bool YtmLyrics = true;
        public string YtmLyricsProxy = PearNowPlaying.YtmLyrics.DefaultProxy;

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
                OverlayPosition pos;
                if (Enum.TryParse(Get(map, "position", c.Position.ToString()), true, out pos)) c.Position = pos;
                c.MarginX = GetInt(map, "marginX", c.MarginX);
                c.MarginY = GetInt(map, "marginY", c.MarginY);
                c.Scale = Clamp(GetDouble(map, "scale", c.Scale), 0.5, 3.0);
                c.PanelWidth = Math.Max(260, Math.Min(1200, GetInt(map, "panelWidth", c.PanelWidth)));
                c.Monitor = Math.Max(0, GetInt(map, "monitor", c.Monitor));
                c.CustomX = Math.Max(0, GetInt(map, "customX", c.CustomX));
                c.CustomY = Math.Max(0, GetInt(map, "customY", c.CustomY));
                c.CustomFromBottom = GetBool(map, "customFromBottom", c.CustomFromBottom);
                c.ShowSeconds = Clamp(GetDouble(map, "showSeconds", c.ShowSeconds), 1, 60);
                c.Opacity = Clamp(GetDouble(map, "opacity", c.Opacity), 0.2, 1.0);
                c.AlwaysShow = GetBool(map, "alwaysShow", c.AlwaysShow);
                c.ShowOnPause = GetBool(map, "showOnPause", c.ShowOnPause);
                c.ShowAlbumArt = GetBool(map, "showAlbumArt", c.ShowAlbumArt);
                c.VideoTitle = GetBool(map, "videoTitle", c.VideoTitle);
                c.ShowLyrics = GetBool(map, "showLyrics", c.ShowLyrics);
                c.LyricsShowNext = GetBool(map, "lyricsShowNext", c.LyricsShowNext);
                c.LyricsOffsetMs = Math.Max(-10000, Math.Min(10000, GetInt(map, "lyricsOffsetMs", c.LyricsOffsetMs)));
                c.LyricsServer = Get(map, "lyricsServer", c.LyricsServer);
                c.YtmLyrics = GetBool(map, "ytmLyrics", c.YtmLyrics);
                c.YtmLyricsProxy = Get(map, "ytmLyricsProxy", c.YtmLyricsProxy);
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
                sb.AppendLine("# Pear Desktop > 플러그인 > API 서버 의 호스트/포트와 같아야 합니다.");
                sb.AppendLine("host=" + Host);
                sb.AppendLine("port=" + Port.ToString(inv));
                sb.AppendLine("https=" + B(Https));
                sb.AppendLine();
                sb.AppendLine("# 위치: TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight, Custom");
                sb.AppendLine("# Custom은 트레이 메뉴의 '위젯 끌어서 옮기기'로 놓은 위치입니다(customX, customY, customFromBottom).");
                sb.AppendLine("position=" + Position);
                sb.AppendLine("# 화면 가장자리로부터의 여백(px)");
                sb.AppendLine("marginX=" + MarginX.ToString(inv));
                sb.AppendLine("marginY=" + MarginY.ToString(inv));
                sb.AppendLine("# 크기 배율 (1.0 = 기본)");
                sb.AppendLine("scale=" + Scale.ToString("0.##", inv));
                sb.AppendLine("# 곡 카드와 가사 카드의 너비(px, 배율 적용 전)");
                sb.AppendLine("panelWidth=" + PanelWidth.ToString(inv));
                sb.AppendLine("# 표시할 모니터 번호 (0 = 주 모니터)");
                sb.AppendLine("monitor=" + Monitor.ToString(inv));
                sb.AppendLine("# 끌어서 놓은 위치: 모니터 왼쪽에서 customX(px), 위(customFromBottom=false) 또는 아래에서 customY(px)");
                sb.AppendLine("customX=" + CustomX.ToString(inv));
                sb.AppendLine("customY=" + CustomY.ToString(inv));
                sb.AppendLine("customFromBottom=" + B(CustomFromBottom));
                sb.AppendLine("# 곡이 바뀌었을 때 표시하는 시간(초)");
                sb.AppendLine("showSeconds=" + ShowSeconds.ToString("0.##", inv));
                sb.AppendLine("# 불투명도 (0.2 ~ 1.0)");
                sb.AppendLine("opacity=" + Opacity.ToString("0.##", inv));
                sb.AppendLine("# true면 사라지지 않고 계속 표시");
                sb.AppendLine("alwaysShow=" + B(AlwaysShow));
                sb.AppendLine("# 일시정지/재생 시에도 잠깐 표시");
                sb.AppendLine("showOnPause=" + B(ShowOnPause));
                sb.AppendLine("showAlbumArt=" + B(ShowAlbumArt));
                sb.AppendLine("# 영상(MV·커버 등, 앨범 곡 제외)에 영상 제목을 표시 (false면 곡 제목, true면 Pear의 Discord 상태와 같은 영상 제목)");
                sb.AppendLine("videoTitle=" + B(VideoTitle));
                sb.AppendLine();
                sb.AppendLine("# 가사 (LRCLIB 싱크 가사가 있는 곡만 표시)");
                sb.AppendLine("showLyrics=" + B(ShowLyrics));
                sb.AppendLine("# 다음 줄 가사도 작게 표시");
                sb.AppendLine("lyricsShowNext=" + B(LyricsShowNext));
                sb.AppendLine("# 가사 타이밍 보정(ms). +면 가사가 더 빨리, -면 더 늦게 나옵니다.");
                sb.AppendLine("lyricsOffsetMs=" + LyricsOffsetMs.ToString(inv));
                sb.AppendLine("lyricsServer=" + LyricsServer);
                sb.AppendLine("# YouTube Music 가사를 먼저 찾고, 실패하면 LRCLIB로 찾기 (Pear Desktop의 YTMusic 가사 제공자와 같은 방식). 메뉴에는 없는 설정입니다.");
                sb.AppendLine("ytmLyrics=" + B(YtmLyrics));
                sb.AppendLine("# YouTube Music 가사 중계 서버 (Pear Desktop이 쓰는 외부 서버)");
                sb.AppendLine("ytmLyricsProxy=" + YtmLyricsProxy);
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
