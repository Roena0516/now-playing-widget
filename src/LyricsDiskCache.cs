using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    /// <summary>
    /// Lyrics found on LRCLIB (or Kugou / NetEase), kept on disk between runs so songs played again don't ask LRCLIB again (its
    /// uncached lookups are often refused as "busy"). One small JSON file per YouTube video ID, under
    /// %LocalAppData%\PearNowPlaying\lyrics-cache. Only found lyrics are stored, never misses or failures;
    /// "find lyrics again" removes the entry. The macOS version keeps the same format (LyricsDiskCache.swift).
    /// </summary>
    internal sealed class LyricsDiskCache
    {
        public static readonly string DefaultDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PearNowPlaying", "lyrics-cache");   // the old name: the cache carries over
        public static readonly TimeSpan MaxAge = TimeSpan.FromDays(90);
        /// <summary>
        /// Entries of older formats are dropped. 2 (1.7.1): 1.6–1.7 could save a same-name song's lyrics for a cover
        /// whose original didn't fit (see LyricsProvider.FromOriginal), so their entries are looked up again once.
        /// 3 (1.7.3): another version's "instrumental" mark could be saved for a remix (see LyricsProvider.Pick).
        /// 4 (1.7.5): a cover could get the singer's own song as its original (see CoverLyrics.OriginalCandidates).
        /// 5 (1.8.5): lyrics longer than their entry said could be saved (see LyricsProvider.LyricsFit).
        /// 6 (1.8.7): another song's lyrics uploaded under this title could be saved (see LyricsProvider.PickByTitle).
        /// 7 (2.0.2): a cover's original titled "artist / song" with the artist spelled otherwise than its channel was
        /// looked up under the artist's name, getting another song of that artist (see CoverLyrics.PrimaryTitle).
        /// </summary>
        const int FormatVersion = 7;
        const string DateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'";
        static readonly Regex VideoId = new Regex(@"^[A-Za-z0-9_-]{11}$");

        readonly string dir;
        readonly int maxEntries;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        readonly object gate = new object();

        public LyricsDiskCache(string dir, int maxEntries = 3000)
        {
            this.dir = dir;
            this.maxEntries = maxEntries;
        }

        /// <summary>
        /// Worth keeping: lyrics (or "instrumental") that came from LRCLIB, or from Kugou / NetEase when LRCLIB answered
        /// it has none (not stand-ins for a busy LRCLIB).
        /// </summary>
        public static bool Keeps(LyricsResult r)
        {
            return r != null && !r.Failed && !r.StandIn && (r.HasSynced || r.Instrumental) && new[] { "LRCLIB", "Kugou", "NetEase" }.Any(s => (r.Source ?? "").StartsWith(s, StringComparison.Ordinal));
        }

        string PathFor(string videoId)
        {
            return videoId != null && VideoId.IsMatch(videoId) ? Path.Combine(dir, videoId + ".json") : null;
        }

        /// <summary>The stored lyrics for a video, or null (none, expired or unreadable).</summary>
        public LyricsResult Load(string videoId)
        {
            var path = PathFor(videoId);
            if (path == null) return null;
            lock (gate)
            {
                try
                {
                    if (!File.Exists(path)) return null;
                    var d = json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as IDictionary<string, object>;
                    DateTime saved;
                    object ver;
                    int version = d != null && d.TryGetValue("version", out ver) && ver is int ? (int)ver : 0;
                    if (d == null || version < FormatVersion || !DateTime.TryParseExact(Str(d, "savedAt"), DateFormat, CultureInfo.InvariantCulture,
                                                             DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out saved)
                        || DateTime.UtcNow - saved > MaxAge)
                    {
                        File.Delete(path);
                        return null;
                    }
                    var lines = new List<LyricLine>();
                    object raw;
                    if (d.TryGetValue("lines", out raw) && raw is IEnumerable)
                        foreach (var o in (IEnumerable)raw)
                        {
                            var l = o as IDictionary<string, object>;
                            object t;
                            if (l == null || !l.TryGetValue("timeMs", out t) || t == null) continue;
                            lines.Add(new LyricLine { TimeMs = Convert.ToInt32(t, CultureInfo.InvariantCulture), Text = Str(l, "text") });
                        }
                    object inst;
                    bool instrumental = d.TryGetValue("instrumental", out inst) && inst is bool && (bool)inst;
                    if (lines.Count == 0 && !instrumental) { File.Delete(path); return null; }
                    return new LyricsResult { Lines = Lrc.FirstPerTime(lines.OrderBy(l => l.TimeMs).ToList()), Instrumental = instrumental, Source = Str(d, "source") };
                }
                catch (Exception ex)
                {
                    Log.Write("INFO lyrics cache: couldn't read " + videoId + " (" + ex.Message + ")");
                    return null;
                }
            }
        }

        public void Save(SongInfo song, LyricsResult r)
        {
            var path = PathFor(song.VideoId);
            if (path == null || !Keeps(r)) return;
            var entry = new Dictionary<string, object>
            {
                { "version", FormatVersion },
                { "videoId", song.VideoId },
                { "title", song.Title ?? "" },
                { "artist", song.Artist ?? "" },
                { "source", r.Source },
                { "instrumental", r.Instrumental },
                { "savedAt", DateTime.UtcNow.ToString(DateFormat, CultureInfo.InvariantCulture) },
                { "lines", r.Lines.Select(l => new Dictionary<string, object> { { "timeMs", l.TimeMs }, { "text", l.Text ?? "" } }).ToList() },
            };
            lock (gate)
            {
                try
                {
                    Directory.CreateDirectory(dir);
                    var tmp = path + ".tmp";
                    File.WriteAllText(tmp, json.Serialize(entry), new UTF8Encoding(false));
                    if (File.Exists(path)) File.Delete(path);
                    File.Move(tmp, path);
                    Prune();
                }
                catch (Exception ex) { Log.Write("INFO lyrics cache: couldn't save " + song.VideoId + " (" + ex.Message + ")"); }
            }
        }

        public void Forget(string videoId)
        {
            var path = PathFor(videoId);
            if (path == null) return;
            lock (gate)
            {
                try { if (File.Exists(path)) File.Delete(path); }
                catch (Exception ex) { Log.Write("INFO lyrics cache: couldn't remove " + videoId + " (" + ex.Message + ")"); }
            }
        }

        /// <summary>Over the limit: drop the oldest entries, down to 90% of it.</summary>
        void Prune()
        {
            var files = new DirectoryInfo(dir).GetFiles("*.json");
            if (files.Length <= maxEntries) return;
            foreach (var f in files.OrderBy(f => f.LastWriteTimeUtc).Take(files.Length - maxEntries * 9 / 10))
                try { f.Delete(); } catch { }
        }

        static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }
    }
}
