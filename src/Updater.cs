using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace PearNowPlaying
{
    internal sealed class UpdateInfo
    {
        public string Version = "", AssetName = "", Url = "", Sha256 = "", PageUrl = "";
    }

    /// <summary>
    /// Updates from this repository's GitHub releases (see VERSIONING.md for the file names it looks for):
    /// the latest release's PearNowPlaying-Windows-a.b.c.zip is downloaded, checked against the SHA-256 GitHub
    /// lists for it, unpacked, and swapped in for the running exe (which Windows lets us rename but not overwrite).
    /// The new exe is started with --wait-for so it starts once this process has exited. Same flow as the macOS
    /// version (Updater.swift).
    /// </summary>
    internal sealed class Updater : IDisposable
    {
        public const string ReleasesApi = "https://api.github.com/repos/Roena0516/pear-now-playing/releases/latest";
        public string ApiUrl = ReleasesApi;
        readonly HttpClient http;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public Updater()
        {
            http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PearNowPlaying/" + AppInfo.Version + " (+https://github.com/Roena0516/pear-now-playing)");
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        }

        /// <summary>The newer release for Windows, or null when this version is the latest. Throws when GitHub can't be asked.</summary>
        public async Task<UpdateInfo> Check(string currentVersion, CancellationToken ct)
        {
            using (var resp = await http.GetAsync(ApiUrl, ct))
            {
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("GitHub releases " + (int)resp.StatusCode);
                var release = json.DeserializeObject(await resp.Content.ReadAsStringAsync()) as IDictionary<string, object>;
                return FromRelease(release, currentVersion, "PearNowPlaying-Windows-", ".zip");
            }
        }

        /// <summary>
        /// The update in a GitHub "latest release" answer: newer than <paramref name="current"/>, and with this
        /// platform's file ("PearNowPlaying-Windows-1.6.0.zip") and its SHA-256 digest. Null otherwise.
        /// </summary>
        public static UpdateInfo FromRelease(IDictionary<string, object> release, string current, string prefix, string extension)
        {
            if (release == null) return null;
            var version = Str(release, "tag_name").TrimStart('v', 'V');
            if (!IsNewer(version, current)) return null;
            var wanted = prefix + version + extension;
            object assets;
            if (!release.TryGetValue("assets", out assets) || !(assets is IEnumerable)) return null;
            foreach (var o in (IEnumerable)assets)
            {
                var a = o as IDictionary<string, object>;
                if (a == null || !string.Equals(Str(a, "name"), wanted, StringComparison.OrdinalIgnoreCase)) continue;
                var digest = Str(a, "digest");
                if (!digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) return null;   // can't be checked: not offered
                return new UpdateInfo
                {
                    Version = version, AssetName = Str(a, "name"), Url = Str(a, "browser_download_url"),
                    Sha256 = digest.Substring(7).ToLowerInvariant(), PageUrl = Str(release, "html_url"),
                };
            }
            return null;
        }

        /// <summary>"1.6.0" newer than "1.5.2"? Missing parts count as 0; anything unreadable is never newer.</summary>
        public static bool IsNewer(string candidate, string current)
        {
            var a = Parse(candidate); var b = Parse(current);
            if (a == null || b == null) return false;
            for (int i = 0; i < 3; i++) if (a[i] != b[i]) return a[i] > b[i];
            return false;
        }

        static int[] Parse(string v)
        {
            var parts = (v ?? "").Trim().TrimStart('v', 'V').Split('.');
            if (parts.Length < 1 || parts.Length > 4) return null;
            var n = new int[3];
            for (int i = 0; i < parts.Length && i < 3; i++)
                if (!int.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out n[i])) return null;
            return n;
        }

        /// <summary>Download the release file into <paramref name="dir"/> and check it against the listed SHA-256.</summary>
        public async Task<string> Download(UpdateInfo update, string dir, CancellationToken ct)
        {
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, update.AssetName);
            using (var resp = await http.GetAsync(update.Url, HttpCompletionOption.ResponseHeadersRead, ct))
            {
                if (!resp.IsSuccessStatusCode) throw new HttpRequestException("download " + (int)resp.StatusCode);
                using (var src = await resp.Content.ReadAsStreamAsync())
                using (var dst = File.Create(path)) await src.CopyToAsync(dst, 81920, ct);
            }
            var actual = Sha256Of(path);
            if (actual != update.Sha256)
            {
                File.Delete(path);
                throw new InvalidDataException("SHA-256 mismatch: expected " + update.Sha256 + ", got " + actual);
            }
            return path;
        }

        public static string Sha256Of(string path)
        {
            using (var sha = SHA256.Create())
            using (var f = File.OpenRead(path))
                return string.Concat(sha.ComputeHash(f).Select(b => b.ToString("x2")));
        }

        /// <summary>
        /// Unpack the release zip and put its files next to <paramref name="exePath"/>: the running exe is renamed
        /// to .old (deleted on the next start) and the new one copied in; README / license are replaced too.
        /// Anything going wrong puts the old exe back and throws.
        /// </summary>
        public static void Install(string zipPath, string exePath, string expectedVersion)
        {
            var work = Path.Combine(Path.GetDirectoryName(zipPath), "unpacked");
            if (Directory.Exists(work)) Directory.Delete(work, true);
            ZipFile.ExtractToDirectory(zipPath, work);
            var newExe = Directory.GetFiles(work, "PearNowPlaying.exe", SearchOption.AllDirectories).FirstOrDefault();
            if (newExe == null) throw new InvalidDataException("PearNowPlaying.exe not in the zip");
            var newVersion = FileVersionInfo.GetVersionInfo(newExe).FileVersion ?? "";
            if (!newVersion.StartsWith(expectedVersion + ".", StringComparison.Ordinal) && newVersion != expectedVersion)
                throw new InvalidDataException("the zip holds version " + newVersion + ", not " + expectedVersion);

            var dir = Path.GetDirectoryName(exePath);
            var old = exePath + ".old";
            if (File.Exists(old)) File.Delete(old);
            File.Move(exePath, old);
            try { File.Copy(newExe, exePath); }
            catch
            {
                try { if (File.Exists(exePath)) File.Delete(exePath); File.Move(old, exePath); } catch { }
                throw;
            }
            foreach (var name in new[] { "README.md", "PretendardJP-OFL.txt" })
            {
                var f = Directory.GetFiles(work, name, SearchOption.AllDirectories).FirstOrDefault();
                if (f != null) try { File.Copy(f, Path.Combine(dir, name), true); } catch { }   // nice to have
            }
        }

        /// <summary>The exe replaced by the last update, removed once the new one runs.</summary>
        public static void CleanupOld(string exePath)
        {
            try { if (File.Exists(exePath + ".old")) File.Delete(exePath + ".old"); } catch { }
        }

        static string Str(IDictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }

        public void Dispose() { http.Dispose(); }
    }
}
