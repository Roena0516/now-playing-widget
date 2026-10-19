import Foundation

/// Small wrapper so the patterns below read like the .NET originals in src/CoverLyrics.cs.
struct Rx {
    let re: NSRegularExpression
    init(_ pattern: String, ignoreCase: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }
    private func all(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
    func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: all(s)) != nil }
    func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: all(s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
    /// Capture groups of the first match ("" for groups that didn't take part), nil when there is no match.
    func firstGroups(_ s: String) -> [String]? { re.firstMatch(in: s, range: all(s)).map { groups($0, in: s) } }
    func allGroups(_ s: String) -> [[String]] { re.matches(in: s, range: all(s)).map { groups($0, in: s) } }
    /// Like .NET Regex.Split for separators without capture groups ("" -> [""]).
    func split(_ s: String) -> [String] {
        var parts: [String] = [], start = s.startIndex
        for m in re.matches(in: s, range: all(s)) {
            guard let r = Range(m.range, in: s), !r.isEmpty else { continue }
            parts.append(String(s[start..<r.lowerBound])); start = r.upperBound
        }
        parts.append(String(s[start...]))
        return parts
    }
    private func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func trimmed(_ chars: String) -> String { trimmingCharacters(in: CharacterSet(charactersIn: chars)) }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

/// Helpers for covers ("歌ってみた" and the like): find the original song's video in the cover's description
/// and tell apart covers whose music differs from the original (arrangements, remixes, acoustic …), where the
/// original's synced lyrics would drift. Port of src/CoverLyrics.cs; keep the two in step.
enum CoverLyrics {
    /// Allowed length difference between cover and original, in seconds.
    static let maxLengthDiff: Double = 10

    static let videoLink = Rx(#"(?:youtu\.be/|youtube\.com/(?:watch\?(?:[^\s]*&)?v=|shorts/|embed/|live/|v/))([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"#, ignoreCase: true)

    // lines that point at the original song
    static let originalHint = Rx(#"原曲|本家|元曲|オリジナル|original|원곡|오리지널|song\s*by|music\s*by|曲\s*[:：/]|作詞作曲|作曲"#, ignoreCase: true)

    // lines that point somewhere else (instrumental, other covers, the singer's channel …)
    /// A title tag saying a song is the singer's own ("【MV】Since 1998.／莉犬【オリジナル曲】"), not the original of this cover.
    static let ownSongTag = Rx(#"[【\[（(]\s*(オリジナル|original)[^】\]）)]*[】\]）)]"#, ignoreCase: true)
    static let otherHint = Rx(#"off\s*vocal|offvocal|inst\b|instrumental|karaoke|カラオケ|オフボーカル|mix\s*[:：]|illust|イラスト|動画\s*[:：]|movie\s*[:：]|前回|previous|playlist|再生リスト|members|メンバー"#, ignoreCase: true)

    // titles whose music differs from the original
    static let arranged = Rx(
        #"remix|rmx|re-?arrange|arrange|アレンジ|リアレンジ|リミックス|편곡|어레인지|리믹스|acoustic|アコースティック|어쿠스틱|unplugged|"# +
        #"piano\s*ver|ピアノ\s*(?:ver|アレンジ|弾き語り)|피아노\s*ver|弾き語り|acapella|a\s*cappella|アカペラ|아카펠라|"# +
        #"orchestra|オーケストラ|오케스트라|jazz|ジャズ|lo-?fi|nightcore|sped\s*up|slowed|8\s*bit|chiptune|オルゴール|music\s*box|"# +
        #"band\s*(?:ver|arrange)|バンド\s*(?:ver|アレンジ)|rock\s*ver|eurobeat|extended|short\s*ver|ショート\s*ver|tv\s*(?:size|ver)|"# +
        #"medley|メドレー|메들리|mashup|マッシュアップ"#, ignoreCase: true)

    /// True when the title says the music was changed (remix, arrangement, acoustic, short version …).
    static func looksArranged(_ title: String) -> Bool { !title.isEmpty && arranged.matches(title) }

    static let coverTitle = Rx(#"cover|カバー|歌ってみた|歌わせて|커버|불러\s*보았|翻唱"#, ignoreCase: true)

    /// Worth looking for an original: user uploads / other videos (or unknown type), or anything whose title
    /// says it is a cover — singers' own channels are often listed as official music videos.
    static func mayBeCover(_ song: Song) -> Bool {
        let t = song.mediaType.trimmed.uppercased()
        if t.isEmpty || t == "USER_GENERATED_CONTENT" || t == "OTHER_VIDEO" { return true }
        if coverTitle.matches(song.title) || coverTitle.matches(song.alternativeTitle) { return true }
        // "ダーリンダンス/かいりきベア【こはならむ】": the title names an artist other than the uploader
        return !guessOriginal(song, description: nil).artist.isEmpty
    }

    // ---- original song from the cover's title / description (when there is no link) -------------

    static let brackets = Rx(#"【([^】]*)】|\[([^\]]*)\]|〖([^〗]*)〗"#)
    static let tagWords = Rx(#"歌ってみた|踊ってみた|弾いてみた|cover|カバー|커버|mv|m/v|official|公式|オリジナル|original|full|フル|ver\.?|version|歌枠|live|ライブ|周年|記念|生誕|誕生日|コラボ|collab|ホロライブ|にじさんじ|vtuber|新衣装|3d"#, ignoreCase: true)
    static let coverTail = Rx(#"\s*[\(\[（]?\s*(?<![A-Za-z])(?:covered\s*by|cover\s*by|cover\s*ver\.?|cover|カバー|커버|歌ってみた|踊ってみた|弾いてみた)(?![A-Za-z])[^\)\]）]*[\)\]）]?"#, ignoreCase: true)
    static let descOriginal = Rx(#"^[^\p{L}\p{N}]*(?:原曲|ご?本家|元曲|original(?:\s*song)?|オリジナル|원곡)\s*(?:様|さま)?\s*[\]】〗」』）)]?\s*[:：\-－/／]?\s*(.+)$"#, ignoreCase: true)
    static let descComposer = Rx(#"^[^\p{L}\p{N}]*(?:music|作詞\s*[・/&]?\s*作曲|作曲|作編曲|composer|song\s*by)\s*[\]】〗」』）)]?\s*[:：\-－/／]\s*(.+)$"#, ignoreCase: true)
    static let quoted = Rx(#"「([^」]+)」|『([^』]+)』|([♕♔♪♬♫★☆♡♥◆◇●○✿❀✨]+)\s*([^♕♔♪♬♫★☆♡♥◆◇●○✿❀✨]+?)\s*\3"#)
    static let subtitles = Rx(#"한글\s*자막|한국어\s*자막|자막|가사|번역|歌詞付き|歌詞|中文字幕|字幕|日本語訳|\blyrics?\s*video\b|\blyrics?\b|\bsub(?:bed|titles?)?\b"#, ignoreCase: true)
    static let honorific = Rx(#"\s*(?:[（(]\s*@[^)）]*[)）])?\s*(?:様|さま|さん|氏)?\s*(?:[（(]\s*@[^)）]*[)）])?\s*$"#)
    static let url = Rx(#"https?://\S+"#, ignoreCase: true)
    static let spaces = Rx(#"[\s　]+"#)
    static let slashes = Rx(#"\s*[/／｜|]\s*"#)
    static let dashes = Rx(#"\s+[-－–—]\s+"#)
    static let feat = Rx(#"(?i)\s+(?:feat\.?|ft\.?)\s.*$"#)

    /// Song title and (if it says so) the original artist, read from a cover's title, e.g.
    /// "ワールドイズマイン / ryo(covered by …)" -> ("ワールドイズマイン", "ryo"),
    /// "【歌ってみた】初めての恋が終わる時 covered by 春猿火" -> ("初めての恋が終わる時", ""),
    /// "神っぽいな / ピノキオピー (cover) - Nqsi" -> ("神っぽいな", "ピノキオピー").
    /// The description is used for the artist when the title doesn't name one ("原曲：… / …", "Music: …").
    static func guessOriginal(_ song: Song, description: String?) -> (title: String, artist: String) {
        var raw = subtitles.replace(song.title, with: " ")
        // 「曲名」 / 『曲名 / 作者』 / ♕曲名♕: the quoted part is the song
        if let q = quoted.firstGroups(raw) {
            let inner = (q[1] + q[2] + q[4]).trimmed
            if !inner.isEmpty && !tagWords.matches(inner) { raw = inner }
        }
        // drop 【tags】; if nothing else is left, the song title was the bracketed part
        let outside = brackets.replace(raw, with: " ").trimmed
        var t = outside
        if clean(outside).isEmpty {
            for m in brackets.allGroups(raw) {
                let inner = (m[1] + m[2] + m[3]).trimmed
                if !inner.isEmpty && !tagWords.matches(inner) { t = inner; break }
            }
        }
        t = coverTail.replace(t, with: " ")
        t = spaces.replace(t, with: " ").trimmed

        let parts = slashes.split(t).map(\.trimmed).filter { !$0.isEmpty }
        var title: String, artist = ""
        if parts.count >= 2 { title = parts[0]; artist = parts[1] }
        else if parts.count == 1 && !dashes.matches(parts[0]) { title = parts[0] }
        else {
            let dash = dashes.split(t).map(\.trimmed).filter { !$0.isEmpty }
            title = dash.first ?? t
            artist = dash.count > 1 ? dash[1] : ""
        }
        // "ピノキオピー - Nqsi": keep the first piece; drop it entirely if it is the singer / channel
        artist = dashes.split(artist)[0].trimmed
        // "DECO*27 - チェリーポップ feat. 初音ミク" uploaded by DECO*27: the first part is the artist, not the song
        if !artist.isEmpty && sameArtist(title, song.artist) { title = artist; artist = "" }
        if isSinger(artist, song) { artist = "" }
        title = clean(title)

        if artist.isEmpty, let description, !description.isEmpty {
            let lines = description.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            for line in lines {
                guard let m = descOriginal.firstGroups(url.replace(line, with: " ")) else { continue }
                let v = honorific.replace(m[1].trimmed, with: "")
                let segs = Rx(#"\s*[/／]\s*"#).split(v).filter { !$0.trimmed.isEmpty }
                // "原曲：ワールドイズマイン / ryo様", "Original: 상록수 feat. 나래 - 호랑풍류가" or "原曲：ryo様"
                if segs.count >= 2 { artist = honorific.replace(segs[1].trimmed, with: "") }
                else if segs.count == 1 { artist = artistBesideTitle(segs[0].trimmed, title) }
                if !norm(artist).isEmpty { break }   // "ご本家様 → (link)" names nobody
                artist = ""
            }
            if artist.isEmpty {
                for line in lines {
                    if let m = descComposer.firstGroups(url.replace(line, with: " ")) { artist = honorific.replace(m[1].trimmed, with: ""); break }
                }
            }
            if isSinger(artist, song) { artist = "" }
        }
        return (title, artist)
    }

    /// "ビノミ - Binomi" / "夜に駆ける (Racing into the Night)" -> "ビノミ" / "夜に駆ける" (unchanged when nothing is left).
    static func primaryTitle(_ title: String, artist: String = "") -> String {
        var t = brackets.replace(title, with: " ").trimmed
        if t.isEmpty { t = title.trimmed }
        var segs = Rx(#"\s+[-－–—]\s+|\s*[/／｜|]\s*"#).split(t).map(\.trimmed).filter { !$0.isEmpty }
        // "DECO*27 - チェリーポップ": the first part is the artist, the song comes after it
        if segs.count >= 2 && sameArtist(segs[0], artist) { segs.removeFirst() }
        if let first = segs.first { t = first }
        t = feat.replace(t, with: "").trimmed
        let noParen = Rx(#"\s*[\(（][^\)）]*[\)）]\s*$"#).replace(t, with: "").trimmed
        return noParen.isEmpty ? t : noParen
    }

    /// Is a linked video plausibly the song the cover sings? Either the cover's title names it, or the two titles
    /// are close. Guards against promo links in the description (the singer's other songs, previous covers …).
    static func titleMatchesCover(_ cover: Song, _ candidate: TrackInfo) -> Bool {
        let cand = norm(primaryTitle(candidate.title, artist: candidate.artist))
        if cand.isEmpty { return false }
        let whole = norm(cover.title + " " + cover.alternativeTitle)
        if cand.count >= 2 && whole.contains(cand) { return true }
        // names the cover's title could be using: the parsed song name, (parenthesised names), / | ㅣ separated parts
        var names = [guessOriginal(cover, description: nil).title]
        names += Rx(#"[\(（「『]([^\)）」』]+)[\)）」』]"#).allGroups(cover.title).map { $0[1] }
        names += Rx(#"\s*[/／｜|ㅣ]\s*|\s+[-－–—]\s+"#).split(brackets.replace(cover.title, with: " "))
        for n in names.map(norm).filter({ $0.count >= 2 }).uniqued() {
            if n == cand || n.contains(cand) || cand.contains(n) || LyricsProvider.jaroWinkler(n, cand) > 0.8 { return true }
        }
        return false
    }

    static func isSinger(_ name: String, _ song: Song) -> Bool {
        let n = norm(name), a = norm(song.artist)
        if n.isEmpty { return true }
        return !a.isEmpty && (n.contains(a) || a.contains(n))
    }

    static func clean(_ s: String) -> String {
        var s = Rx(#"[「」『』"“”]"#).replace(s, with: " ")
        s = Rx(#"(?i)\b(?:mv|m/v|official|full)\b"#).replace(s, with: " ")
        return spaces.replace(s, with: " ").trimmed(" -－/|:：")
    }

    /// Same artist name, ignoring case, width, punctuation and accents ("fhána" = "fhana").
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let x = norm(stripAccents(a))
        return !x.isEmpty && x == norm(stripAccents(b))
    }

    static func stripAccents(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.decomposedStringWithCanonicalMapping.unicodeScalars where u.properties.generalCategory != .nonspacingMark { out.append(u) }
        return String(out).precomposedStringWithCanonicalMapping
    }

    static let filler = Rx(#"music\s*video|lyric\s*video|official|audio|video|ミュージックビデオ|オリジナル|original|\bmv\b|\bm/v\b|\bpv\b|teaser|full|ver\.?|version|歌ってみた|cover|カバー|커버|\bfeat\.?.*$|\bft\.?.*$"#, ignoreCase: true)
    static let japanese = Rx(#"[\p{Block=Hiragana}\p{Block=Katakana}\p{Block=CJK_Unified_Ideographs}ー]"#)
    static let mixedNames = Rx(#"^(.*[\p{Block=Hiragana}\p{Block=Katakana}\p{Block=CJK_Unified_Ideographs}ー])\s+([A-Za-z][\x20-\x7E]*)$"#)

    /// Every name a video title may give the song, the likeliest first:
    /// "サイエンス - Science" -> サイエンス, Science; "ヨルシカ - だから僕は音楽を辞めた (Music Video) - That's Why …"
    /// (artist Yorushika) -> だから僕は音楽を辞めた, That's Why …; "恋愛裁判 Love Trial" -> 恋愛裁判 Love Trial, 恋愛裁判, Love Trial.
    /// Parts that are the artist or just "MUSIC VIDEO"-like words are left out. `extra` names go last.
    static func titleNames(_ title: String, artist: String, extra: [String] = []) -> [String] {
        var names: [String] = [], seen = Set<String>()
        func add(_ raw: String) {
            let s = feat.replace(raw, with: "").trimmed
            let n = norm(s)
            if n.isEmpty || norm(filler.replace(s, with: " ")).isEmpty { return }
            if sameArtist(s, artist) || !seen.insert(n).inserted { return }
            names.append(s)
        }
        let guess = guessOriginal(Song(title: title, artist: artist), description: nil).title
        if !guess.isEmpty { add(primaryTitle(guess, artist: artist)) }
        add(primaryTitle(title, artist: artist))

        var parts: [String] = []
        for seg in Rx(#"\s+[-－–—]\s+|\s*[/／｜|]\s*|\s+l\s+"#).split(brackets.replace(title, with: " ")) {
            let s = seg.trimmed
            if s.isEmpty { continue }
            // "夜に駆ける (Racing into the Night)": the outside and the inside are both names
            if let p = Rx(#"^(.*?)\s*[\(（]([^\)）]+)[\)）]\s*$"#).firstGroups(s) { parts += [p[1], p[2]] } else { parts.append(s) }
        }
        for p in parts {
            add(p)
            // "恋愛裁判 Love Trial": the Japanese and the English name side by side
            if let m = mixedNames.firstGroups(p), japanese.matches(m[1]), !japanese.matches(m[2]) { add(m[1]); add(m[2]) }
        }
        extra.forEach(add)
        return names
    }

    /// NFKC, lower case, letters and digits only (char.IsLetterOrDigit in the Windows version).
    static func norm(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: out.append(u)
            default: break
            }
        }
        return String(out)
    }

    static let featTail = Rx(#"\s*(?:[\(（\[]\s*(?:feat|ft)\b\.?[^\)）\]]*[\)）\]]|\s(?:feat|ft)\.?\s.*)\s*$"#, ignoreCase: true)

    /// The title to show for an album track. YouTube Music hands Pear the title in the app's language: a track
    /// whose label registered a translated title shows only the translation ("Only Words"), while YouTube
    /// Music's own queue lists it as "original - translation" ("心を刺す言葉だけ - Only Words (feat. …)").
    /// When the queue title is exactly that pair and its second half is Pear's title, show both; otherwise
    /// (no translation, Pear already showing the original, titles that merely contain " - ") keep Pear's title.
    /// "(feat. …)" follows Pear's title: kept if Pear has it, not added otherwise. Same as src/CoverLyrics.cs.
    /// The artist in "artist - title" or "title - artist" (the side that isn't the song), the whole text when it
    /// isn't the song itself, or "". Same as src/CoverLyrics.cs.
    static func artistBesideTitle(_ text: String, _ title: String) -> String {
        let dash = dashes.split(text).map(\.trimmed).filter { !$0.isEmpty }
        if dash.count == 2 && sameTitle(dash[1], title) { return dash[0] }
        if dash.count == 2 && sameTitle(dash[0], title) { return dash[1] }
        return norm(text) != norm(title) ? text : ""
    }
    /// The original title when Pear has only the translation (the first half of the queue's "original - translation",
    /// see displayTitle), or nil. Same as src/CoverLyrics.cs.
    static func originalTitle(_ pearTitle: String, queueTitle: String) -> String? {
        if displayTitle(pearTitle, queueTitle: queueTitle) == pearTitle { return nil }
        return dashes.split(featTail.replace(queueTitle, with: "").trimmed)[0].trimmed
    }
    /// "カナデトモスソラ ねこぼーろver." -> "カナデトモスソラ": a "○○ver." that only names who sings it. Arrangements
    /// ("Acoustic ver.", "piano ver.") stay as they are, since their timing differs.
    static func withoutVersionTag(_ title: String) -> String {
        if title.isEmpty || looksArranged(title) { return title }
        let t = Rx(#"[\s\u3000]+\S*\s*(?:ver\.?|version)\s*$"#, ignoreCase: true).replace(title, with: "").trimmed
        return t.isEmpty ? title : t
    }
    /// Artist names written beside the song in a video title: "チュルリラ・チュルリラ・ダッダッダ！ - 和田たけあき(くらげP) /
    /// Chururira … - KurageP" -> "和田たけあき(くらげP)". YouTube Music may give the channel's romanized name
    /// ("WADATAKEAKI KurageP") while LRCLIB lists the one in the title. Same as src/CoverLyrics.cs.
    static func artistsInTitle(_ title: String, songName: String) -> [String] {
        Rx(#"\s*[/／｜|]\s*"#).split(title).compactMap { part in
            let dash = dashes.split(part).map(\.trimmed).filter { !$0.isEmpty }
            guard dash.count == 2 else { return nil }
            if sameTitle(dash[0], songName) && !sameTitle(dash[1], songName) { return dash[1] }
            if sameTitle(dash[1], songName) && !sameTitle(dash[0], songName) { return dash[0] }
            return nil
        }
    }
    /// "心を刺す言葉だけ - Only Words" -> both halves (a song LRCLIB may list under either), else none. Same as src/CoverLyrics.cs.
    static func titleHalves(_ title: String) -> [String] {
        let parts = dashes.split(title).map(\.trimmed)
        return parts.count == 2 && parts.allSatisfy({ !norm($0).isEmpty }) ? parts : []
    }
    static func displayTitle(_ pearTitle: String, queueTitle: String) -> String {
        if pearTitle.trimmed.isEmpty || queueTitle.trimmed.isEmpty { return pearTitle }
        let core = featTail.replace(pearTitle, with: "").trimmed
        let feat = String(pearTitle.trimmed.dropFirst(core.count))
        let parts = dashes.split(featTail.replace(queueTitle, with: "").trimmed)
        guard parts.count == 2, !parts[0].trimmed.isEmpty, norm(parts[1]) == norm(core) else { return pearTitle }
        // halves that differ only in symbols ("Xaleid◆scopiX - Xaleid_scopiX"): the same name retyped, so the original alone
        if norm(parts[0]) == norm(core) { return parts[0].trimmed + feat }
        return parts[0].trimmed + " - " + parts[1].trimmed + feat
    }

    /// Does a search hit's title name the same song? (case/width/punctuation ignored; "(feat. …)" etc. allowed)
    static func sameTitle(_ hit: String, _ wanted: String) -> Bool {
        let a = norm(Rx(#"[\(\[（【][^\)\]）】]*[\)\]）】]"#).replace(hit, with: " ")), b = norm(wanted)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if min(a.count, b.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        return LyricsProvider.jaroWinkler(a, b) > 0.93
    }

    /// Up to six video IDs from the description (each costs a request only if the ones before it were no use), the likeliest original first: links on lines that say
    /// "原曲 / 本家 / original / 원곡 …", then other links in order. Links on off-vocal / mix / illust lines last.
    /// `hinted`: IDs whose line (or the line above) says 原曲 / 本家 / original / 원곡.
    /// The text that says what a link is: its own line and the line above ("原曲" / URL), and one more line up when
    /// those belong to the same block ("■ご本家様：…" / "プロポーズ / 可不" / URL). A blank line or another link ends the block.
    static func hintContext(_ lines: [String], _ i: Int) -> String {
        var context = lines[i]
        if i > 0 { context += " " + lines[i - 1] }
        if i > 1, !lines[i - 1].trimmed.isEmpty, !videoLink.matches(lines[i - 1]), !lines[i - 2].trimmed.isEmpty, !videoLink.matches(lines[i - 2]) {
            context += " " + lines[i - 2]
        }
        return context
    }
    static func originalCandidates(_ desc: VideoDescription?, ownId: String) -> (ids: [String], hinted: Set<String>) {
        guard let desc else { return ([], []) }
        var hinted = Set<String>()
        var scored: [(id: String, score: Int, order: Int)] = []
        let lines = desc.text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            for m in videoLink.allGroups(line) {
                let context = hintContext(lines, i)
                var score = originalHint.matches(ownSongTag.replace(context, with: " ")) ? 2 : 0
                if score > 0 { hinted.insert(m[1]) }
                if otherHint.matches(context) { score -= 3 }
                scored.append((m[1], score, scored.count))
            }
        }
        for id in desc.linkedIds { scored.append((id, 0, scored.count)) }
        var best: [String: (id: String, score: Int, order: Int)] = [:]
        for s in scored where s.id != ownId {
            if let b = best[s.id], b.score > s.score || (b.score == s.score && b.order < s.order) { continue }
            best[s.id] = s
        }
        let ids = best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .filter { $0.score > -3 }.prefix(6).map(\.id)
        return (Array(ids), hinted)
    }
}
