import Foundation

/// Cover-song parsing must give the same answers as the Windows version (src/CoverLyrics.cs).
/// Expected values were produced by running these inputs through the C# code.
@MainActor func runCoverTests() {
    func check(_ ok: Bool, _ what: String) { precondition(ok, "Cover parsing differs from Windows: " + what) }
    do { let g = CoverLyrics.guessOriginal(Song(title: "ワールドイズマイン / ryo(covered by 誰か)", artist: "誰か"), description: ""); check(g.title == "ワールドイズマイン" && g.artist == "ryo", "ワールドイズマイン / ryo(covered by 誰か)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "【歌ってみた】初めての恋が終わる時 covered by 春猿火", artist: "春猿火"), description: ""); check(g.title == "初めての恋が終わる時" && g.artist == "", "【歌ってみた】初めての恋が終わる時 covered by 春猿火") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "神っぽいな / ピノキオピー (cover) - Nqsi", artist: "Nqsi"), description: ""); check(g.title == "神っぽいな" && g.artist == "ピノキオピー", "神っぽいな / ピノキオピー (cover) - Nqsi") }
    // description lines with an emoji or "ご" before the label, and "artist - title" after it (expected values from src/CoverLyrics.cs)
    do { let g = CoverLyrics.guessOriginal(Song(title: "호랑풍류가 [나와 호랑이님 OST] / 코가네 랑 (Cogane Rang) Cover", artist: "코가네 랑 COGANE RANG"), description: "🐯Original: 상록수 feat. 나래(Narae) - 호랑풍류가\nhttps://youtu.be/fBQhY7tfx4k"); check(g.title == "호랑풍류가" && g.artist == "상록수 feat. 나래(Narae)", "호랑풍류가 (🐯Original: artist - title)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "「メランコリック」covered by 雨衣", artist: "VoiSona公式"), description: "Vocal : 雨衣\nご本家様 → https://youtu.be/86_kvUqhY-A"); check(g.title == "メランコリック" && g.artist == "", "メランコリック (ご本家様 → link names nobody)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "ヴァンパイア 歌ってみた", artist: "X"), description: "■ご本家様：DECO*27 様\nhttps://youtu.be/e1xCOsgWG0M"); check(g.title == "ヴァンパイア" && g.artist == "DECO*27", "ヴァンパイア (■ご本家様：DECO*27 様)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "Song cover", artist: "X"), description: "원곡: Song - Artist Name"); check(g.title == "Song" && g.artist == "Artist Name", "Song (원곡: title - artist)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "DECO*27 - チェリーポップ feat. 初音ミク", artist: "DECO*27"), description: ""); check(g.title == "チェリーポップ feat. 初音ミク" && g.artist == "", "DECO*27 - チェリーポップ feat. 初音ミク") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "ダーリンダンス/かいりきベア【こはならむ】", artist: "こはならむ"), description: ""); check(g.title == "ダーリンダンス" && g.artist == "かいりきベア", "ダーリンダンス/かいりきベア【こはならむ】") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "This Game「ノーゲーム・ノーライフ」OPテーマ", artist: "x"), description: ""); check(g.title == "ノーゲーム・ノーライフ" && g.artist == "", "This Game「ノーゲーム・ノーライフ」OPテーマ") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "【MV】可愛くてごめん / HoneyWorks", artist: "HoneyWorks"), description: ""); check(g.title == "可愛くてごめん" && g.artist == "", "【MV】可愛くてごめん / HoneyWorks") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "♪ 夜に駆ける ♪ 歌ってみた", artist: "someone"), description: ""); check(g.title == "夜に駆ける" && g.artist == "", "♪ 夜に駆ける ♪ 歌ってみた") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "Lemon (cover)", artist: "Singer"), description: "原曲：米津玄師様\nhttps://youtu.be/SX_ViT4Ra7k"); check(g.title == "Lemon" && g.artist == "米津玄師", "Lemon (cover)") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "シャルル 歌ってみた", artist: "A"), description: "Music: バルーン"); check(g.title == "シャルル" && g.artist == "バルーン", "シャルル 歌ってみた") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "『KING / Kanaria』 cover", artist: "B"), description: ""); check(g.title == "KING" && g.artist == "Kanaria", "『KING / Kanaria』 cover") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "아이돌 (YOASOBI) 한글 자막", artist: "C"), description: ""); check(g.title == "아이돌 (YOASOBI)" && g.artist == "", "아이돌 (YOASOBI) 한글 자막") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "Unknown Mother-Goose / wowaka【歌ってみた】ver. Sou", artist: "Sou"), description: ""); check(g.title == "Unknown Mother-Goose" && g.artist == "", "Unknown Mother-Goose / wowaka【歌ってみた】ver. Sou") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "【歌ってみた】ロウワー / ぬゆり", artist: "まふまふ"), description: "原曲様：ロウワー / ぬゆり様(@nulut)\n作詞作曲：ぬゆり"); check(g.title == "ロウワー" && g.artist == "ぬゆり", "【歌ってみた】ロウワー / ぬゆり") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "ヴァンパイア covered by Ado", artist: "Ado"), description: "作詞・作曲：DECO*27"); check(g.title == "ヴァンパイア" && g.artist == "DECO*27", "ヴァンパイア covered by Ado") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "[Cover] 夜に駆ける - YOASOBI | ○○", artist: "○○"), description: ""); check(g.title == "夜に駆ける - YOASOBI" && g.artist == "", "[Cover] 夜に駆ける - YOASOBI | ○○") }
    do { let g = CoverLyrics.guessOriginal(Song(title: "〖歌ってみた〗アイドル 〖YOASOBI〗", artist: "Z"), description: ""); check(g.title == "アイドル" && g.artist == "", "〖歌ってみた〗アイドル 〖YOASOBI〗") }
    check(CoverLyrics.titleNames("サイエンス - Science", artist: "MIMI", extra: []) == ["サイエンス", "Science"], "サイエンス - Science")
    check(CoverLyrics.titleNames("ヨルシカ - だから僕は音楽を辞めた (Music Video) - That's Why I Gave Up on Music", artist: "ヨルシカ", extra: []) == ["だから僕は音楽を辞めた", "That's Why I Gave Up on Music"], "ヨルシカ - だから僕は音楽を辞めた (Music Video) - That's Why I Gave Up on Music")
    check(CoverLyrics.titleNames("恋愛裁判 Love Trial", artist: "40mP", extra: []) == ["恋愛裁判 Love Trial", "恋愛裁判", "Love Trial"], "恋愛裁判 Love Trial")
    check(CoverLyrics.titleNames("夜に駆ける (Racing into the Night)", artist: "YOASOBI", extra: []) == ["夜に駆ける", "Racing into the Night"], "夜に駆ける (Racing into the Night)")
    check(CoverLyrics.titleNames("【MV】Imperial Girl / R Sound Design feat. 初音ミク", artist: "R Sound Design", extra: ["帝国少女"]) == ["Imperial Girl", "帝国少女"], "【MV】Imperial Girl / R Sound Design feat. 初音ミク")
    check(CoverLyrics.titleNames("YOASOBI「アイドル」 Official Music Video", artist: "YOASOBI", extra: []) == ["アイドル", "YOASOBI「アイドル」 Official Music Video"], "YOASOBI「アイドル」 Official Music Video")
    check(CoverLyrics.titleNames("Ado l うっせぇわ", artist: "Ado", extra: []) == ["Ado l うっせぇわ", "うっせぇわ"], "Ado l うっせぇわ")
    check(CoverLyrics.primaryTitle("ビノミ - Binomi", artist: "") == "ビノミ", "ビノミ - Binomi")
    check(CoverLyrics.primaryTitle("DECO*27 - チェリーポップ", artist: "DECO*27") == "チェリーポップ", "DECO*27 - チェリーポップ")
    check(CoverLyrics.primaryTitle("夜に駆ける (Racing into the Night)", artist: "") == "夜に駆ける", "夜に駆ける (Racing into the Night)")
    check(CoverLyrics.primaryTitle("Song feat. X", artist: "") == "Song", "Song feat. X")
    check(CoverLyrics.primaryTitle("【MV】ロキ", artist: "みきとP") == "ロキ", "【MV】ロキ")
    check(CoverLyrics.sameTitle("サイエンス (feat. 初音ミク)", "サイエンス") == true, "サイエンス (feat. 初音ミク)")
    check(CoverLyrics.sameTitle("Science", "サイエンス") == false, "Science")
    check(CoverLyrics.sameTitle("Love Trial", "Love Trial (2022)") == true, "Love Trial")
    check(CoverLyrics.sameTitle("ヴァンパイア", "ヴァンパイヤ") == true, "ヴァンパイア")
    check(CoverLyrics.sameTitle("アイドル", "アイドル (English Ver.)") == true, "アイドル")
    check(CoverLyrics.sameArtist("fhána", "fhana") == true, "fhána")
    check(CoverLyrics.sameArtist("ＤＥＣＯ＊２７", "DECO*27") == true, "ＤＥＣＯ＊２７")
    check(CoverLyrics.sameArtist("Ado", "ado ") == true, "Ado")
    check(CoverLyrics.sameArtist("米津玄師", "Kenshi Yonezu") == false, "米津玄師")
    check(CoverLyrics.looksArranged("Lemon (Piano ver.)") == true, "Lemon (Piano ver.)")
    check(CoverLyrics.looksArranged("Lemon") == false, "Lemon")
    check(CoverLyrics.looksArranged("夜に駆ける 弾き語り") == true, "夜に駆ける 弾き語り")
    check(CoverLyrics.looksArranged("Extended Mix") == true, "Extended Mix")
    check(CoverLyrics.looksArranged("アイドル TV size") == true, "アイドル TV size")
    check(CoverLyrics.looksArranged("Rearrange") == true, "Rearrange")
    check(CoverLyrics.looksArranged("Short Ver.") == true, "Short Ver.")
    check(CoverLyrics.mayBeCover(Song(title: "Lemon", artist: "米津玄師", mediaType: "AUDIO")) == false, "Lemon AUDIO")
    check(CoverLyrics.mayBeCover(Song(title: "Lemon", artist: "米津玄師", mediaType: "USER_GENERATED_CONTENT")) == true, "Lemon USER_GENERATED_CONTENT")
    check(CoverLyrics.mayBeCover(Song(title: "Lemon (cover)", artist: "Someone", mediaType: "ORIGINAL_MUSIC_VIDEO")) == true, "Lemon (cover) ORIGINAL_MUSIC_VIDEO")
    check(CoverLyrics.mayBeCover(Song(title: "ダーリンダンス/かいりきベア【こはならむ】", artist: "こはならむ", mediaType: "ORIGINAL_MUSIC_VIDEO")) == true, "ダーリンダンス/かいりきベア【こはならむ】 ORIGINAL_MUSIC_VIDEO")
    check(CoverLyrics.mayBeCover(Song(title: "Lemon", artist: "米津玄師", mediaType: "UNKNOWN")) == false, "Lemon UNKNOWN")
    check(CoverLyrics.mayBeCover(Song(title: "Lemon", artist: "米津玄師", mediaType: "")) == true, "Lemon ")
    check(CoverLyrics.titleMatchesCover(Song(title: "【歌ってみた】ヴァンパイア / DECO*27 covered by X", artist: "X"), TrackInfo(title: "DECO*27 - ヴァンパイア feat. 初音ミク", artist: "DECO*27")) == true, "DECO*27 - ヴァンパイア feat. 初音ミク")
    check(CoverLyrics.titleMatchesCover(Song(title: "【歌ってみた】ヴァンパイア / DECO*27 covered by X", artist: "X"), TrackInfo(title: "DECO*27 - ラビットホール feat. 初音ミク", artist: "DECO*27")) == false, "DECO*27 - ラビットホール feat. 初音ミク")
    check(CoverLyrics.titleMatchesCover(Song(title: "Imperial Girl / 帝国少女 歌ってみた", artist: "Y"), TrackInfo(title: "R Sound Design - 帝国少女", artist: "R Sound Design")) == true, "R Sound Design - 帝国少女")
    let candidates = CoverLyrics.originalCandidates(VideoDescription(text: "原曲 / 本家\nhttps://www.youtube.com/watch?v=AAAAAAAAAAA\nMix: https://youtu.be/BBBBBBBBBBB\n前回の歌ってみた https://youtu.be/CCCCCCCCCCC\nhttps://youtu.be/DDDDDDDDDDD\nhttps://www.youtube.com/watch?list=x&v=EEEEEEEEEEE\nhttps://youtu.be/AAAAAAAAAAA", linkedIds: ["FFFFFFFFFFF"]), ownId: "EEEEEEEEEEE")
    check(candidates.ids == ["AAAAAAAAAAA", "FFFFFFFFFFF"] && candidates.hinted == Set(["AAAAAAAAAAA"]), "original candidates")
    // "■ご本家様" two lines above its link, and the singer's own songs tagged 【オリジナル曲】 aren't originals (莉犬's プロポーズ)
    let riinu = CoverLyrics.originalCandidates(VideoDescription(text: "■ご本家様：内緒のピアス 様\nプロポーズ / 可不\nhttps://youtu.be/AAAAAAAAAAA\n■Mix：Y STUDIO 様\n\n🍓【MV】わんぬ／莉犬\nhttps://youtu.be/BBBBBBBBBBB\n\n🍓【MV】Since 1998.／莉犬【オリジナル曲】\nhttps://youtu.be/CCCCCCCCCCC"), ownId: "x")
    check(riinu.ids == ["AAAAAAAAAAA", "BBBBBBBBBBB", "CCCCCCCCCCC"] && riinu.hinted == Set(["AAAAAAAAAAA"]), "original candidates: ご本家様 block")
    print("PASS: cover parsing matches the Windows version (title/artist guesses, song names, arrangements, cover detection, original links)")
}

/// Album track titles ("original - translation") must match the Windows version (expected values from src/CoverLyrics.cs).
@MainActor func runDisplayTitleTests() {
    precondition(CoverLyrics.displayTitle("Only Words", queueTitle: "心を刺す言葉だけ - Only Words (feat. HATSUNE MIKU & KAFU)") == "心を刺す言葉だけ - Only Words", "display title: Only Words")
    precondition(CoverLyrics.displayTitle("Only Words", queueTitle: "心を刺す言葉だけ - Only Words (feat. HATSUNE MIKU, KAFU)") == "心を刺す言葉だけ - Only Words", "display title: Only Words")
    precondition(CoverLyrics.displayTitle("命に嫌われている", queueTitle: "命に嫌われている (feat. Yoisaki Kanade, Shinonome Ena, Hatsune Miku)") == "命に嫌われている", "display title: 命に嫌われている")
    precondition(CoverLyrics.displayTitle("밤편지", queueTitle: "밤편지 - Through the Night") == "밤편지", "display title: 밤편지")
    precondition(CoverLyrics.displayTitle("サイエンス - Science", queueTitle: "サイエンス - Science") == "サイエンス - Science", "display title: サイエンス - Science")
    precondition(CoverLyrics.displayTitle("Only Words (feat. KAFU)", queueTitle: "心を刺す言葉だけ - Only Words (feat. KAFU)") == "心を刺す言葉だけ - Only Words (feat. KAFU)", "display title: Only Words (feat. KAFU)")
    precondition(CoverLyrics.displayTitle("ALiCE", queueTitle: "ALiCE") == "ALiCE", "display title: ALiCE")
    precondition(CoverLyrics.displayTitle("Song", queueTitle: "") == "Song", "display title: Song")
    precondition(CoverLyrics.displayTitle("Title", queueTitle: "A - B - Title") == "Title", "display title: Title")
    precondition(CoverLyrics.displayTitle("only words", queueTitle: "心を刺す言葉だけ - Only Words") == "心を刺す言葉だけ - Only Words", "display title: only words")
    precondition(CoverLyrics.displayTitle("Lemon", queueTitle: "Lemon - レモン") == "Lemon", "display title: Lemon")
    precondition(CoverLyrics.displayTitle("Night Dancer feat. X", queueTitle: "夜のダンサー - Night Dancer feat. X") == "夜のダンサー - Night Dancer feat. X", "display title: Night Dancer feat. X")
    precondition(CoverLyrics.displayTitle("Xaleid_scopiX", queueTitle: "Xaleid◆scopiX - Xaleid_scopiX") == "Xaleid◆scopiX", "display title: Xaleid◆scopiX")
    precondition(CoverLyrics.displayTitle("Lemon", queueTitle: "Lemon - Lemon") == "Lemon", "display title: Lemon - Lemon")
    // the original title for lyrics searches, and a singer's "○○ver." dropped (expected values from src/CoverLyrics.cs)
    precondition(CoverLyrics.originalTitle("kanade tomosu sora nekobolo version", queueTitle: "カナデトモスソラ　ねこぼーろver. - kanade tomosu sora nekobolo version") == "カナデトモスソラ　ねこぼーろver.", "original title: カナデトモスソラ")
    precondition(CoverLyrics.originalTitle("Only Words", queueTitle: "心を刺す言葉だけ - Only Words (feat. KAFU)") == "心を刺す言葉だけ", "original title: Only Words")
    precondition(CoverLyrics.originalTitle("Lemon", queueTitle: "Lemon") == nil && CoverLyrics.originalTitle("Xaleid_scopiX", queueTitle: "Xaleid◆scopiX - Xaleid_scopiX") == "Xaleid◆scopiX", "original title: none / symbols only")
    precondition(CoverLyrics.withoutVersionTag("カナデトモスソラ　ねこぼーろver.") == "カナデトモスソラ", "version tag: singer's ver.")
    precondition(CoverLyrics.withoutVersionTag("夜に駆ける Acoustic ver.") == "夜に駆ける Acoustic ver." && CoverLyrics.withoutVersionTag("Lemon") == "Lemon" && CoverLyrics.withoutVersionTag("ver.") == "ver.", "version tag: arrangements kept")
    print("PASS: album track titles shown as original - translation, like the Windows version")
}
