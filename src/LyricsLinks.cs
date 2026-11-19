using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    /// <summary>
    /// Which YouTube Music track's timed lyrics a video got: a cover's original (" · 원곡") or a music video's official
    /// audio (" · 공식 음원"). Finding that track takes 5–10 requests (the description, the original, its artist and
    /// album pages), 3–12 s; with the link kept, the next time the video plays only that track's lyrics are asked for
    /// (about 1 s; user's request 2026-11-20, for shuffling a big playlist). The lyrics themselves aren't kept (YouTube
    /// Music's aren't saved to disk, LyricsDiskCache). Kept in lyrics-links.json next to the lyrics cache, oldest first;
    /// links older than 90 days are dropped. Same format as the macOS version (LyricsLinks.swift).
    /// </summary>
    internal sealed class LyricsLinks
    {
        public static readonly string DefaultPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PearNowPlaying", "lyrics-links.json");
        const int Version = 1, MaxDays = 90, MaxEntries = 10000;
        static readonly Regex VideoId = new Regex(@"^[A-Za-z0-9_-]{11}$");

        internal sealed class Link { public string Id, From, Source; public int Day; }

        readonly string path;
        readonly object gate = new object();
        readonly List<Link> links = new List<Link>();   // oldest first

        public LyricsLinks(string path) { this.path = path; Load(); }

        static int Today { get { return (int)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalDays; } }

        /// <summary>Only another video's lyrics from YouTube Music are worth a link.</summary>
        public static bool Keeps(string videoId, LyricsResult r)
        {
            return r != null && r.HasSynced && !string.IsNullOrEmpty(r.FromVideo) && r.FromVideo != videoId
                   && VideoId.IsMatch(videoId ?? "") && VideoId.IsMatch(r.FromVideo)
                   && (r.Source ?? "").StartsWith("YouTube Music · ", StringComparison.Ordinal);
        }

        public Link Get(string videoId)
        {
            lock (gate) return links.FirstOrDefault(l => l.Id == videoId && Today - l.Day <= MaxDays);
        }

        public void Set(string videoId, LyricsResult r)
        {
            if (!Keeps(videoId, r)) return;
            lock (gate)
            {
                links.RemoveAll(l => l.Id == videoId || Today - l.Day > MaxDays);
                links.Add(new Link { Id = videoId, From = r.FromVideo, Source = r.Source, Day = Today });
                while (links.Count > MaxEntries) links.RemoveAt(0);
                Save();
            }
        }

        public void Forget(string videoId) { lock (gate) { if (links.RemoveAll(l => l.Id == videoId) > 0) Save(); } }

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
                    object id, from, source, day;
                    if (!e.TryGetValue("id", out id) || !VideoId.IsMatch(id as string ?? "") || !e.TryGetValue("from", out from) || !VideoId.IsMatch(from as string ?? "")
                        || !e.TryGetValue("source", out source) || !(source as string ?? "").StartsWith("YouTube Music · ", StringComparison.Ordinal)
                        || !e.TryGetValue("day", out day) || !(day is int)) continue;
                    links.RemoveAll(l => l.Id == (string)id);
                    links.Add(new Link { Id = (string)id, From = (string)from, Source = (string)source, Day = (int)day });
                }
            }
            catch (Exception ex) { Log.Write("WARN lyrics links file unreadable: " + ex.Message); }
        }

        void Save()
        {
            try
            {
                var d = new Dictionary<string, object>
                {
                    { "version", Version },
                    { "videos", links.Select(l => new Dictionary<string, object> { { "id", l.Id }, { "from", l.From }, { "source", l.Source }, { "day", l.Day } }).ToList() },
                };
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, new JavaScriptSerializer().Serialize(d), new UTF8Encoding(false));
            }
            catch (Exception ex) { Log.Write("WARN lyrics links not saved: " + ex.Message); }
        }
    }
}
