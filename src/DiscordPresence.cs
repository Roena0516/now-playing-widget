using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    /// <summary>What Discord shows: a song being listened to, or nothing.</summary>
    internal sealed class DiscordActivity
    {
        public string Title = "", Artist = "", Album = "", ImageUrl = "", VideoId = "";
        /// <summary>When the song started and ends (UTC), for Discord's progress bar.</summary>
        public DateTime Start, End;
        public bool Button;

        /// <summary>Close enough that sending it again would only use up Discord's rate limit (positions drift by
        /// the clock; a seek moves the start by more than 3 seconds).</summary>
        public bool Same(DiscordActivity other)
        {
            return other != null && Title == other.Title && Artist == other.Artist && Album == other.Album && ImageUrl == other.ImageUrl && VideoId == other.VideoId
                && Button == other.Button && Math.Abs((Start - other.Start).TotalSeconds) < 3 && Math.Abs((End - other.End).TotalSeconds) < 3;
        }
    }

    /// <summary>
    /// "Listening to" on the user's Discord profile (Rich Presence), through the Discord app's local IPC pipe
    /// (\\.\pipe\discord-ipc-N): no server of ours, and nothing when Discord isn't running. Only songs from the
    /// browser are shown (Pear Desktop has its own Discord plugin), and only when the user turns it on (config
    /// discordPresence). Same as macos/Sources/DiscordPresence.swift.
    /// </summary>
    internal sealed class DiscordPresence : IDisposable
    {
        public const string ClientId = "1562020013953515553";
        public const string ProjectUrl = "https://github.com/Roena0516/pear-now-playing";
        // Discord takes about 5 activity updates per 20 seconds
        static readonly TimeSpan MinGap = TimeSpan.FromSeconds(4);

        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly SemaphoreSlim wake = new SemaphoreSlim(0);
        readonly CancellationTokenSource cts = new CancellationTokenSource();
        readonly object gate = new object();
        DiscordActivity wanted, sent;
        bool sentAny;
        bool loggedMissing;

        public DiscordPresence() { Task.Run(() => Loop(cts.Token)); }

        /// <summary>The activity to show (null: none). Sent when it differs from the last one, at Discord's pace.</summary>
        public void Show(DiscordActivity activity)
        {
            lock (gate) wanted = activity;
            wake.Release();
        }

        async Task Loop(CancellationToken ct)
        {
            NamedPipeClientStream pipe = null;
            DateTime lastSend = DateTime.MinValue;
            while (!ct.IsCancellationRequested)
            {
                try { await wake.WaitAsync(TimeSpan.FromSeconds(15), ct); } catch (OperationCanceledException) { break; }
                DiscordActivity next;
                lock (gate) next = wanted;
                bool clear = next == null;
                if (clear ? !sentAny || sent == null : next.Same(sent)) continue;
                if (clear && pipe == null) { sent = null; continue; }   // nothing shown: no need to connect
                var wait = lastSend + MinGap - DateTime.UtcNow;
                if (wait > TimeSpan.Zero) { try { await Task.Delay(wait, ct); } catch (OperationCanceledException) { break; } lock (gate) next = wanted; clear = next == null; }
                try
                {
                    if (pipe == null || !pipe.IsConnected) { pipe = Connect(); if (pipe == null) continue; }
                    Write(pipe, 1, new Dictionary<string, object>
                    {
                        { "cmd", "SET_ACTIVITY" }, { "nonce", Guid.NewGuid().ToString() },
                        { "args", new Dictionary<string, object> { { "pid", System.Diagnostics.Process.GetCurrentProcess().Id }, { "activity", clear ? null : Activity(next) } } },
                    });
                    lastSend = DateTime.UtcNow;
                    sent = next; sentAny = true;
                }
                catch (Exception ex)
                {
                    Log.Write("INFO Discord: " + ex.Message + ", trying again later");
                    try { if (pipe != null) pipe.Dispose(); } catch { }
                    pipe = null; sent = null;
                }
            }
            try { if (pipe != null) pipe.Dispose(); } catch { }
        }

        /// <summary>Discord's activity object: "Listening" with the song, its cover, progress and the project's button.</summary>
        internal static Dictionary<string, object> Activity(DiscordActivity a)
        {
            var activity = new Dictionary<string, object>
            {
                { "type", 2 },                    // Listening
                { "status_display_type", 2 },     // the member list shows the song ("details"), not the app's name
                { "details", Field(a.Title) },
                { "state", Field(a.Artist) },
                { "timestamps", new Dictionary<string, object> { { "start", Millis(a.Start) }, { "end", Millis(a.End) } } },
            };
            // the title (and the cover) open the song on YouTube Music
            var link = YtmLyrics.IsVideoId(a.VideoId) ? "https://music.youtube.com/watch?v=" + a.VideoId : null;
            if (link != null) activity["details_url"] = link;
            if (a.ImageUrl.StartsWith("https://", StringComparison.Ordinal))
            {
                var assets = new Dictionary<string, object> { { "large_image", a.ImageUrl }, { "large_text", Field(a.Album.Length > 0 ? a.Album : a.Title) } };
                if (link != null) assets["large_url"] = link;
                activity["assets"] = assets;
            }
            if (a.Button)
                activity["buttons"] = new object[] { new Dictionary<string, object> { { "label", "Now Playing Widget" }, { "url", ProjectUrl } } };
            return activity;
        }

        /// <summary>Discord takes 2 to 128 characters (padded with a blank that isn't whitespace, so it isn't trimmed away).</summary>
        internal static string Field(string s)
        {
            s = (s ?? "").Trim();
            if (s.Length > 128) s = s.Substring(0, 127) + "…";
            return s.PadRight(2, '\u2800');
        }

        static long Millis(DateTime utc) { return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        /// <summary>The first Discord pipe that answers the handshake, or null (Discord isn't running).</summary>
        NamedPipeClientStream Connect()
        {
            for (int i = 0; i < 10; i++)
            {
                var pipe = new NamedPipeClientStream(".", "discord-ipc-" + i, PipeDirection.InOut, PipeOptions.Asynchronous);
                try
                {
                    pipe.Connect(200);
                    Write(pipe, 0, new Dictionary<string, object> { { "v", 1 }, { "client_id", ClientId } });
                    var ready = Read(pipe);
                    if (ready == null || !ready.Contains("\"READY\"")) throw new IOException("handshake answered " + (ready ?? "nothing"));
                    Log.Info("Discord: connected (discord-ipc-" + i + ")");
                    loggedMissing = false;
                    // answers to later commands are read and dropped, so the pipe never fills up
                    Task.Run(() => { try { while (Read(pipe) != null) { } } catch { } });
                    return pipe;
                }
                catch (TimeoutException) { pipe.Dispose(); }
                catch (Exception ex) { pipe.Dispose(); Log.Write("INFO Discord: discord-ipc-" + i + ": " + ex.Message); }
            }
            if (!loggedMissing) { loggedMissing = true; Log.Info("Discord isn't running; the listening status waits for it"); }
            return null;
        }

        void Write(Stream pipe, int opcode, object payload)
        {
            var body = Encoding.UTF8.GetBytes(json.Serialize(payload));
            var frame = new byte[8 + body.Length];
            BitConverter.GetBytes(opcode).CopyTo(frame, 0);
            BitConverter.GetBytes(body.Length).CopyTo(frame, 4);
            body.CopyTo(frame, 8);
            pipe.Write(frame, 0, frame.Length);
            pipe.Flush();
        }

        /// <summary>One frame's JSON, or null when the pipe closed.</summary>
        static string Read(Stream pipe)
        {
            var header = ReadExactly(pipe, 8);
            if (header == null) return null;
            int length = BitConverter.ToInt32(header, 4);
            if (length < 0 || length > 1 << 20) return null;
            var body = ReadExactly(pipe, length);
            return body == null ? null : Encoding.UTF8.GetString(body);
        }

        static byte[] ReadExactly(Stream s, int count)
        {
            var buffer = new byte[count];
            int read = 0;
            while (read < count)
            {
                int n = s.Read(buffer, read, count - read);
                if (n <= 0) return null;
                read += n;
            }
            return buffer;
        }

        public void Dispose()
        {
            Show(null);
            try { cts.CancelAfter(1500); } catch { }
        }
    }
}
