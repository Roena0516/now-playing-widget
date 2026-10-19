using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace PearNowPlaying
{
    /// <summary>
    /// Helpers for covers ("歌ってみた" and the like): find the original song's video in the cover's description
    /// and tell apart covers whose music differs from the original (arrangements, remixes, acoustic …), where the
    /// original's synced lyrics would drift.
    /// </summary>
    internal static class CoverLyrics
    {
        /// <summary>Allowed length difference between cover and original, in seconds.</summary>
        public const double MaxLengthDiff = 10;

        static readonly Regex VideoLink = new Regex(
            @"(?:youtu\.be/|youtube\.com/(?:watch\?(?:[^\s]*&)?v=|shorts/|embed/|live/|v/))([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])",
            RegexOptions.IgnoreCase);

        // lines that point at the original song
        static readonly Regex OriginalHint = new Regex(
            @"原曲|本家|元曲|オリジナル|original|원곡|오리지널|song\s*by|music\s*by|曲\s*[:：/]|作詞作曲|作曲",
            RegexOptions.IgnoreCase);

        // a title tag saying a song is the singer's own ("【MV】Since 1998.／莉犬【オリジナル曲】"), not the original of this cover
        static readonly Regex OwnSongTag = new Regex(@"[【\[（(]\s*(オリジナル|original)[^】\]）)]*[】\]）)]", RegexOptions.IgnoreCase);

        // lines that point somewhere else (instrumental, other covers, the singer's channel …)
        static readonly Regex OtherHint = new Regex(
            @"off\s*vocal|offvocal|inst\b|instrumental|karaoke|カラオケ|オフボーカル|mix\s*[:：]|illust|イラスト|動画\s*[:：]|movie\s*[:：]|前回|previous|playlist|再生リスト|members|メンバー",
            RegexOptions.IgnoreCase);

        // titles whose music differs from the original
        static readonly Regex Arranged = new Regex(
            @"remix|rmx|re-?arrange|arrange|アレンジ|リアレンジ|リミックス|편곡|어레인지|리믹스|acoustic|アコースティック|어쿠스틱|unplugged|" +
            @"piano\s*ver|ピアノ\s*(?:ver|アレンジ|弾き語り)|피아노\s*ver|弾き語り|acapella|a\s*cappella|アカペラ|아카펠라|" +
            @"orchestra|オーケストラ|오케스트라|jazz|ジャズ|lo-?fi|nightcore|sped\s*up|slowed|8\s*bit|chiptune|オルゴール|music\s*box|" +
            @"band\s*(?:ver|arrange)|バンド\s*(?:ver|アレンジ)|rock\s*ver|eurobeat|extended|short\s*ver|ショート\s*ver|tv\s*(?:size|ver)|" +
            @"medley|メドレー|메들리|mashup|マッシュアップ",
            RegexOptions.IgnoreCase);

        /// <summary>True when the title says the music was changed (remix, arrangement, acoustic, short version …).</summary>
        public static bool LooksArranged(string title)
        {
            return !string.IsNullOrEmpty(title) && Arranged.IsMatch(title);
        }

        static readonly Regex CoverTitle = new Regex(
            @"cover|カバー|歌ってみた|歌わせて|커버|불러\s*보았|翻唱", RegexOptions.IgnoreCase);

        /// <summary>
        /// Worth looking for an original: user uploads / other videos (or unknown type), or anything whose title
        /// says it is a cover — singers' own channels are often listed as official music videos.
        /// </summary>
        public static bool MayBeCover(SongInfo song)
        {
            var t = (song.MediaType ?? "").Trim().ToUpperInvariant();
            if (t.Length == 0 || t == "USER_GENERATED_CONTENT" || t == "OTHER_VIDEO") return true;
            if (CoverTitle.IsMatch(song.Title ?? "") || CoverTitle.IsMatch(song.AltTitle ?? "")) return true;
            // "ダーリンダンス/かいりきベア【こはならむ】": the title names an artist other than the uploader
            return GuessOriginal(song, null).Item2.Length > 0;
        }

        // ---- original song from the cover's title / description (when there is no link) -------------

        static readonly Regex Brackets = new Regex(@"【([^】]*)】|\[([^\]]*)\]|〖([^〗]*)〗");
        static readonly Regex TagWords = new Regex(
            @"歌ってみた|踊ってみた|弾いてみた|cover|カバー|커버|mv|m/v|official|公式|オリジナル|original|full|フル|ver\.?|version|歌枠|live|ライブ|周年|記念|生誕|誕生日|コラボ|collab|ホロライブ|にじさんじ|vtuber|新衣装|3d",
            RegexOptions.IgnoreCase);
        static readonly Regex CoverTail = new Regex(
            @"\s*[\(\[（]?\s*(?<![A-Za-z])(?:covered\s*by|cover\s*by|cover\s*ver\.?|cover|カバー|커버|歌ってみた|踊ってみた|弾いてみた)(?![A-Za-z])[^\)\]）]*[\)\]）]?",
            RegexOptions.IgnoreCase);
        static readonly Regex DescOriginal = new Regex(
            @"^[^\p{L}\p{N}]*(?:原曲|ご?本家|元曲|original(?:\s*song)?|オリジナル|원곡)\s*(?:様|さま)?\s*[\]】〗」』）)]?\s*[:：\-－/／]?\s*(.+)$",
            RegexOptions.IgnoreCase);
        static readonly Regex DescComposer = new Regex(
            @"^[^\p{L}\p{N}]*(?:music|作詞\s*[・/&]?\s*作曲|作曲|作編曲|composer|song\s*by)\s*[\]】〗」』）)]?\s*[:：\-－/／]\s*(.+)$",
            RegexOptions.IgnoreCase);
        static readonly Regex Quoted = new Regex(@"「([^」]+)」|『([^』]+)』|([♕♔♪♬♫★☆♡♥◆◇●○✿❀✨]+)\s*([^♕♔♪♬♫★☆♡♥◆◇●○✿❀✨]+?)\s*\3");
        static readonly Regex Subtitles = new Regex(
            @"한글\s*자막|한국어\s*자막|자막|가사|번역|歌詞付き|歌詞|中文字幕|字幕|日本語訳|\blyrics?\s*video\b|\blyrics?\b|\bsub(?:bed|titles?)?\b",
            RegexOptions.IgnoreCase);
        static readonly Regex Honorific = new Regex(@"\s*(?:[（(]\s*@[^)）]*[)）])?\s*(?:様|さま|さん|氏)?\s*(?:[（(]\s*@[^)）]*[)）])?\s*$");
        static readonly Regex Url = new Regex(@"https?://\S+", RegexOptions.IgnoreCase);

        /// <summary>
        /// Song title and (if it says so) the original artist, read from a cover's title, e.g.
        /// "ワールドイズマイン / ryo(covered by …)" -> ("ワールドイズマイン", "ryo"),
        /// "【歌ってみた】初めての恋が終わる時 covered by 春猿火" -> ("初めての恋が終わる時", ""),
        /// "神っぽいな / ピノキオピー (cover) - Nqsi" -> ("神っぽいな", "ピノキオピー").
        /// The description is used for the artist when the title doesn't name one ("原曲：… / …", "Music: …").
        /// </summary>
        public static Tuple<string, string> GuessOriginal(SongInfo song, string description)
        {
            var raw = Subtitles.Replace(song.Title ?? "", " ");
            // 「曲名」 / 『曲名 / 作者』 / ♕曲名♕: the quoted part is the song
            var quoted = Quoted.Match(raw);
            if (quoted.Success)
            {
                var q = (quoted.Groups[1].Value + quoted.Groups[2].Value + quoted.Groups[4].Value).Trim();
                if (q.Length > 0 && !TagWords.IsMatch(q)) raw = q;
            }
            // drop 【tags】; if nothing else is left, the song title was the bracketed part
            var outside = Brackets.Replace(raw, " ").Trim();
            string t = outside;
            if (Clean(outside).Length == 0)
                foreach (Match m in Brackets.Matches(raw))
                {
                    var inner = (m.Groups[1].Value + m.Groups[2].Value + m.Groups[3].Value).Trim();
                    if (inner.Length > 0 && !TagWords.IsMatch(inner)) { t = inner; break; }
                }
            t = CoverTail.Replace(t, " ");
            t = Regex.Replace(t, @"[\s\u3000]+", " ").Trim();

            var parts = Regex.Split(t, @"\s*[/／｜|]\s*").Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
            string title, artist = "";
            if (parts.Count >= 2) { title = parts[0]; artist = parts[1]; }
            else if (parts.Count == 1 && !Regex.IsMatch(parts[0], @"\s+[-－–—]\s+")) title = parts[0];
            else
            {
                var dash = Regex.Split(t, @"\s+[-－–—]\s+").Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
                title = dash.Count > 0 ? dash[0] : t;
                artist = dash.Count > 1 ? dash[1] : "";
            }
            // "ピノキオピー - Nqsi": keep the first piece; drop it entirely if it is the singer / channel
            artist = Regex.Split(artist, @"\s+[-－–—]\s+")[0].Trim();
            // "DECO*27 - チェリーポップ feat. 初音ミク" uploaded by DECO*27: the first part is the artist, not the song
            if (artist.Length > 0 && SameArtist(title, song.Artist)) { title = artist; artist = ""; }
            if (IsSinger(artist, song)) artist = "";
            title = Clean(title);

            if (artist.Length == 0 && !string.IsNullOrEmpty(description))
            {
                foreach (var line in description.Replace("\r", "").Split('\n'))
                {
                    var m = DescOriginal.Match(Url.Replace(line, " "));
                    if (!m.Success) continue;
                    var v = Honorific.Replace(m.Groups[1].Value.Trim(), "");
                    var segs = Regex.Split(v, @"\s*[/／]\s*").Where(x => x.Trim().Length > 0).ToList();
                    // "原曲：ワールドイズマイン / ryo様", "Original: 상록수 feat. 나래 - 호랑풍류가" or "原曲：ryo様"
                    if (segs.Count >= 2) artist = Honorific.Replace(segs[1].Trim(), "");
                    else if (segs.Count == 1) artist = ArtistBesideTitle(segs[0].Trim(), title);
                    if (Norm(artist).Length > 0) break;   // "ご本家様 → (link)" names nobody
                    artist = "";
                }
                if (artist.Length == 0)
                    foreach (var line in description.Replace("\r", "").Split('\n'))
                    {
                        var m = DescComposer.Match(Url.Replace(line, " "));
                        if (m.Success) { artist = Honorific.Replace(m.Groups[1].Value.Trim(), ""); break; }
                    }
                if (IsSinger(artist, song)) artist = "";
            }
            return Tuple.Create(title, artist);
        }

        /// <summary>
        /// The artist in "artist - title" or "title - artist" (the side that isn't the song), the whole text when it
        /// isn't the song itself, or "".
        /// </summary>
        static string ArtistBesideTitle(string text, string title)
        {
            var dash = Regex.Split(text, @"\s+[-－–—]\s+").Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
            if (dash.Count == 2 && SameTitle(dash[1], title)) return dash[0];
            if (dash.Count == 2 && SameTitle(dash[0], title)) return dash[1];
            return Norm(text) != Norm(title) ? text : "";
        }

        /// <summary>"ビノミ - Binomi" / "夜に駆ける (Racing into the Night)" -> "ビノミ" / "夜に駆ける" (unchanged when nothing is left).</summary>
        public static string PrimaryTitle(string title, string artist = null)
        {
            var t = Brackets.Replace(title ?? "", " ").Trim();
            if (t.Length == 0) t = (title ?? "").Trim();
            var segs = Regex.Split(t, @"\s+[-－–—]\s+|\s*[/／｜|]\s*").Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
            // "DECO*27 - チェリーポップ": the first part is the artist, the song comes after it
            if (segs.Count >= 2 && SameArtist(segs[0], artist)) segs.RemoveAt(0);
            if (segs.Count > 0) t = segs[0];
            t = Regex.Replace(t, @"(?i)\s+(?:feat\.?|ft\.?)\s.*$", "").Trim();
            var noParen = Regex.Replace(t, @"\s*[\(（][^\)）]*[\)）]\s*$", "").Trim();
            return noParen.Length > 0 ? noParen : t;
        }

        /// <summary>
        /// Is a linked video plausibly the song the cover sings? Either the cover's title names it, or the two titles
        /// are close. Guards against promo links in the description (the singer's other songs, previous covers …).
        /// </summary>
        public static bool TitleMatchesCover(SongInfo cover, TrackInfo candidate)
        {
            var cand = Norm(PrimaryTitle(candidate.Title, candidate.Artist));
            if (cand.Length == 0) return false;
            var whole = Norm((cover.Title ?? "") + " " + (cover.AltTitle ?? ""));
            if (cand.Length >= 2 && whole.Contains(cand)) return true;
            // names the cover's title could be using: the parsed song name, (parenthesised names), / | ㅣ separated parts
            var names = new List<string> { GuessOriginal(cover, null).Item1 };
            foreach (Match m in Regex.Matches(cover.Title ?? "", @"[\(（「『]([^\)）」』]+)[\)）」』]")) names.Add(m.Groups[1].Value);
            names.AddRange(Regex.Split(Brackets.Replace(cover.Title ?? "", " "), @"\s*[/／｜|ㅣ]\s*|\s+[-－–—]\s+"));
            foreach (var n in names.Select(Norm).Where(x => x.Length >= 2).Distinct())
                if (n == cand || n.Contains(cand) || cand.Contains(n) || LyricsProvider.JaroWinkler(n, cand) > 0.8) return true;
            return false;
        }

        static bool IsSinger(string name, SongInfo song)
        {
            var n = Norm(name);
            var a = Norm(song.Artist);
            if (n.Length == 0) return true;
            return a.Length > 0 && (n.Contains(a) || a.Contains(n));
        }

        static string Clean(string s)
        {
            s = Regex.Replace(s ?? "", @"[「」『』""“”]", " ");
            s = Regex.Replace(s, @"(?i)\b(?:mv|m/v|official|full)\b", " ");
            return Regex.Replace(s, @"[\s\u3000]+", " ").Trim(' ', '-', '－', '/', '|', ':', '：');
        }

        /// <summary>Same artist name, ignoring case, width, punctuation and accents ("fhána" = "fhana").</summary>
        internal static bool SameArtist(string a, string b)
        {
            var x = Norm(StripAccents(a));
            return x.Length > 0 && x == Norm(StripAccents(b));
        }

        static string StripAccents(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new System.Text.StringBuilder();
            foreach (var ch in s.Normalize(System.Text.NormalizationForm.FormD))
                if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(ch) != System.Globalization.UnicodeCategory.NonSpacingMark) sb.Append(ch);
            return sb.ToString().Normalize(System.Text.NormalizationForm.FormC);
        }

        static readonly Regex Filler = new Regex(
            @"music\s*video|lyric\s*video|official|audio|video|ミュージックビデオ|オリジナル|original|\bmv\b|\bm/v\b|\bpv\b|teaser|full|ver\.?|version|歌ってみた|cover|カバー|커버|\bfeat\.?.*$|\bft\.?.*$",
            RegexOptions.IgnoreCase);
        static readonly Regex Japanese = new Regex(@"[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}ー]");

        /// <summary>
        /// Every name a video title may give the song, the likeliest first:
        /// "サイエンス - Science" -> サイエンス, Science; "ヨルシカ - だから僕は音楽を辞めた (Music Video) - That's Why …"
        /// (artist Yorushika) -> だから僕は音楽を辞めた, That's Why …; "恋愛裁判 Love Trial" -> 恋愛裁判 Love Trial, 恋愛裁判, Love Trial.
        /// Parts that are the artist or just "MUSIC VIDEO"-like words are left out. <paramref name="extra"/> names go last.
        /// </summary>
        public static List<string> TitleNames(string title, string artist, params string[] extra)
        {
            var names = new List<string>();
            var seen = new HashSet<string>();
            Action<string> add = s =>
            {
                s = Regex.Replace(s ?? "", @"(?i)\s+(?:feat\.?|ft\.?)\s.*$", "").Trim();
                var n = Norm(s);
                if (n.Length == 0 || Norm(Filler.Replace(s, " ")).Length == 0) return;
                if (SameArtist(s, artist) || !seen.Add(n)) return;
                names.Add(s);
            };
            var song = new SongInfo { Title = title, Artist = artist };
            var guess = GuessOriginal(song, null).Item1;
            if (guess.Length > 0) add(PrimaryTitle(guess, artist));
            add(PrimaryTitle(title, artist));

            var noBrackets = Brackets.Replace(title ?? "", " ");
            var parts = new List<string>();
            foreach (var seg in Regex.Split(noBrackets, @"\s+[-－–—]\s+|\s*[/／｜|]\s*|\s+l\s+"))
            {
                var s = seg.Trim();
                if (s.Length == 0) continue;
                // "夜に駆ける (Racing into the Night)": the outside and the inside are both names
                var paren = Regex.Match(s, @"^(.*?)\s*[\(（]([^\)）]+)[\)）]\s*$");
                if (paren.Success) { parts.Add(paren.Groups[1].Value); parts.Add(paren.Groups[2].Value); }
                else parts.Add(s);
            }
            foreach (var p in parts)
            {
                add(p);
                // "恋愛裁判 Love Trial": the Japanese and the English name side by side
                var mixed = Regex.Match(p, @"^(.*[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}ー])\s+([A-Za-z][\x20-\x7E]*)$");
                if (mixed.Success && Japanese.IsMatch(mixed.Groups[1].Value) && !Japanese.IsMatch(mixed.Groups[2].Value))
                {
                    add(mixed.Groups[1].Value);
                    add(mixed.Groups[2].Value);
                }
            }
            if (extra != null) foreach (var e in extra) add(e);
            return names;
        }

        internal static string Norm(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new System.Text.StringBuilder();
            foreach (var ch in s.Normalize(System.Text.NormalizationForm.FormKC).ToLowerInvariant())
                if (char.IsLetterOrDigit(ch)) sb.Append(ch);
            return sb.ToString();
        }

        static readonly Regex FeatTail = new Regex(@"\s*(?:[\(（\[]\s*(?:feat|ft)\b\.?[^\)）\]]*[\)）\]]|\s(?:feat|ft)\.?\s.*)\s*$", RegexOptions.IgnoreCase);

        /// <summary>
        /// The title to show for an album track. YouTube Music hands Pear the title in the app's language: a track
        /// whose label registered a translated title shows only the translation ("Only Words"), while YouTube
        /// Music's own queue lists it as "original - translation" ("心を刺す言葉だけ - Only Words (feat. …)").
        /// When the queue title is exactly that pair and its second half is Pear's title, show both; otherwise
        /// (no translation, Pear already showing the original, titles that merely contain " - ") keep Pear's title.
        /// "(feat. …)" follows Pear's title: kept if Pear has it, not added otherwise. When the two halves differ
        /// only in symbols ("Xaleid◆scopiX - Xaleid_scopiX"), the "translation" is the same name retyped, so only the
        /// original is shown.
        /// </summary>
        /// <summary>
        /// The original title when Pear has only the translation (the first half of the queue's
        /// "original - translation", see DisplayTitle), or null.
        /// </summary>
        public static string OriginalTitle(string pearTitle, string queueTitle)
        {
            if (DisplayTitle(pearTitle, queueTitle) == pearTitle) return null;
            return Regex.Split(FeatTail.Replace(queueTitle, "").Trim(), @"\s+[-－–—]\s+")[0].Trim();
        }

        /// <summary>
        /// "カナデトモスソラ ねこぼーろver." -> "カナデトモスソラ": a "○○ver." that only names who sings it. Arrangements
        /// ("Acoustic ver.", "piano ver.") stay as they are, since their timing differs.
        /// </summary>
        public static string WithoutVersionTag(string title)
        {
            if (string.IsNullOrEmpty(title) || LooksArranged(title)) return title ?? "";
            var t = Regex.Replace(title, @"[\s\u3000]+\S*\s*(?:ver\.?|version)\s*$", "", RegexOptions.IgnoreCase).Trim();
            return t.Length > 0 ? t : title;
        }

        public static string DisplayTitle(string pearTitle, string queueTitle)
        {
            if (string.IsNullOrWhiteSpace(pearTitle) || string.IsNullOrWhiteSpace(queueTitle)) return pearTitle ?? "";
            var core = FeatTail.Replace(pearTitle, "").Trim();
            var feat = pearTitle.Trim().Substring(core.Length);
            var parts = Regex.Split(FeatTail.Replace(queueTitle, "").Trim(), @"\s+[-－–—]\s+");
            if (parts.Length != 2 || parts[0].Trim().Length == 0) return pearTitle;
            if (Norm(parts[1]) != Norm(core)) return pearTitle;
            if (Norm(parts[0]) == Norm(core)) return parts[0].Trim() + feat;
            return parts[0].Trim() + " - " + parts[1].Trim() + feat;
        }

        /// <summary>Does a search hit's title name the same song? (case/width/punctuation ignored; "(feat. …)" etc. allowed)</summary>
        public static bool SameTitle(string hit, string wanted)
        {
            var a = Norm(Regex.Replace(hit ?? "", @"[\(\[（【][^\)\]）】]*[\)\]）】]", " "));
            var b = Norm(wanted);
            if (a.Length == 0 || b.Length == 0) return false;
            if (a == b) return true;
            if (Math.Min(a.Length, b.Length) >= 3 && (a.StartsWith(b) || b.StartsWith(a))) return true;
            return LyricsProvider.JaroWinkler(a, b) > 0.93;
        }

        /// <summary>
        /// Up to six video IDs from the description (each costs a request only if the ones before it were no use), the likeliest original first: links on lines that say
        /// "原曲 / 本家 / original / 원곡 …", then other links in order. Links on off-vocal / mix / illust lines last.
        /// </summary>
        public static List<string> OriginalCandidates(VideoDescription desc, string ownId)
        {
            HashSet<string> hinted;
            return OriginalCandidates(desc, ownId, out hinted);
        }

        /// <param name="hinted">IDs whose line (or the line above) says 原曲 / 本家 / original / 원곡.</param>
        /// <summary>
        /// The text that says what a link is: its own line and the line above ("原曲" / URL), and one more line up when
        /// those belong to the same block ("■ご本家様：…" / "プロポーズ / 可不" / URL). A blank line or another link ends the block.
        /// </summary>
        static string HintContext(string[] lines, int i)
        {
            var context = lines[i];
            if (i > 0) context += " " + lines[i - 1];
            if (i > 1 && !string.IsNullOrWhiteSpace(lines[i - 1]) && !VideoLink.IsMatch(lines[i - 1])
                && !string.IsNullOrWhiteSpace(lines[i - 2]) && !VideoLink.IsMatch(lines[i - 2]))
                context += " " + lines[i - 2];
            return context;
        }

        public static List<string> OriginalCandidates(VideoDescription desc, string ownId, out HashSet<string> hinted)
        {
            hinted = new HashSet<string>();
            var scored = new List<Tuple<string, int, int>>();   // id, score, order
            if (desc == null) return new List<string>();
            var lines = (desc.Text ?? "").Replace("\r", "").Split('\n');
            int order = 0;
            for (int i = 0; i < lines.Length; i++)
            {
                foreach (Match m in VideoLink.Matches(lines[i]))
                {
                    var id = m.Groups[1].Value;
                    var context = HintContext(lines, i);
                    int score = OriginalHint.IsMatch(OwnSongTag.Replace(context, " ")) ? 2 : 0;
                    if (score > 0) hinted.Add(id);
                    if (OtherHint.IsMatch(context)) score -= 3;
                    scored.Add(Tuple.Create(id, score, order++));
                }
            }
            foreach (var id in desc.LinkedIds) scored.Add(Tuple.Create(id, 0, order++));
            return scored
                .Where(t => t.Item1 != ownId)
                .GroupBy(t => t.Item1).Select(g => g.OrderByDescending(t => t.Item2).ThenBy(t => t.Item3).First())
                .OrderByDescending(t => t.Item2).ThenBy(t => t.Item3)
                .Where(t => t.Item2 > -3)
                .Select(t => t.Item1).Take(6).ToList();
        }
    }
}
