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
    /// Lyrics timing set for one video (가사 타이밍 → 이 곡), added to the timing for all songs (lyricsOffsetMs). A cover
    /// gets its original's lyrics, and its singing often starts a little earlier or later than the original's. Kept in
    /// lyrics-timing.json next to config.ini, oldest change first, so the oldest go when there are too many. The macOS
    /// version keeps the same format (LyricsTiming.swift).
    /// </summary>
    internal sealed class LyricsTiming
    {
        public const int Limit = 30000;   // ms either way
        const int Version = 1;
        static readonly Regex VideoId = new Regex(@"^[A-Za-z0-9_-]{11}$");

        public static string DefaultPath { get { return Path.Combine(Config.Dir, "lyrics-timing.json"); } }

        readonly string path;
        readonly int maxEntries;
        readonly Dictionary<string, int> values = new Dictionary<string, int>();
        readonly List<string> order = new List<string>();   // oldest change first

        public LyricsTiming(string path, int maxEntries = 5000)
        {
            this.path = path;
            this.maxEntries = maxEntries;
            Load();
        }

        public static bool CanKeep(string videoId) { return videoId != null && VideoId.IsMatch(videoId); }

        /// <summary>The timing for a video in ms (+ = lyrics earlier), 0 when none was set.</summary>
        public int For(string videoId)
        {
            int ms;
            return videoId != null && values.TryGetValue(videoId, out ms) ? ms : 0;
        }

        /// <summary>Sets a video's timing (0 forgets it) and saves the file. Returns the value kept (clamped).</summary>
        public int Set(string videoId, int ms)
        {
            if (!CanKeep(videoId)) return 0;
            ms = Math.Max(-Limit, Math.Min(Limit, ms));
            order.Remove(videoId);
            values.Remove(videoId);
            if (ms != 0)
            {
                values[videoId] = ms;
                order.Add(videoId);
                while (order.Count > maxEntries) { values.Remove(order[0]); order.RemoveAt(0); }
            }
            Save();
            return ms;
        }

        void Load()
        {
            try
            {
                if (!File.Exists(path)) return;
                var d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as IDictionary<string, object>;
                object list;
                if (d == null || !d.TryGetValue("videos", out list) || !(list is IEnumerable)) return;
                foreach (var e in ((IEnumerable)list).OfType<IDictionary<string, object>>())
                {
                    object id, ms;
                    if (!e.TryGetValue("id", out id) || !CanKeep(id as string) || !e.TryGetValue("ms", out ms) || !(ms is int) || (int)ms == 0) continue;
                    var key = (string)id;
                    if (values.ContainsKey(key)) order.Remove(key);
                    values[key] = Math.Max(-Limit, Math.Min(Limit, (int)ms));
                    order.Add(key);
                }
                while (order.Count > maxEntries) { values.Remove(order[0]); order.RemoveAt(0); }
            }
            catch (Exception ex) { Log.Write("WARN lyrics timing file unreadable: " + ex.Message); }
        }

        void Save()
        {
            try
            {
                var d = new Dictionary<string, object>
                {
                    { "version", Version },
                    { "videos", order.Select(id => new Dictionary<string, object> { { "id", id }, { "ms", values[id] } }).ToList() },
                };
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, new JavaScriptSerializer().Serialize(d), new UTF8Encoding(false));
            }
            catch (Exception ex) { Log.Write("WARN lyrics timing not saved: " + ex.Message); }
        }

        /// <summary>How a timing reads in the menu and messages: "기본", "0.3초 빠르게", "1초 늦게" (+ = lyrics earlier).</summary>
        public static string Text(int ms)
        {
            if (ms == 0) return "기본";
            return (Math.Abs(ms) / 1000.0).ToString("0.##", CultureInfo.InvariantCulture) + "초 " + (ms > 0 ? "빠르게" : "늦게");
        }
    }
}
