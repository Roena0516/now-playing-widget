import Foundation

/// The app's texts in three languages, like the Windows version's L (src/Strings.cs, the same table). The Korean
/// text is the one written in the code and is the key here: L.t("가사 표시") gives "Show lyrics" in English and
/// "歌詞を表示" in Japanese, and the Korean itself when a text has no entry. The language comes from the config
/// ("language": auto, ko, en, ja; auto follows macOS's language, Korean and Japanese as they are and English for
/// everything else). A text added or changed here is added or changed in src/Strings.cs too.
enum L {
    enum Language: String { case ko, en, ja }
    static var language = resolve("auto")

    /// The language a "language" setting means.
    static func resolve(_ setting: String) -> Language {
        if let chosen = Language(rawValue: setting) { return chosen }
        let os = Locale.preferredLanguages.first ?? "en"
        return os.hasPrefix("ko") ? .ko : os.hasPrefix("ja") ? .ja : .en
    }
    static func use(_ setting: String) { language = resolve(setting) }

    /// A text in the current language.
    static func t(_ ko: String) -> String {
        guard language != .ko, let other = table[ko] else { return ko }
        return other[language == .ja ? 1 : 0]
    }

    /// A text with {0}, {1} filled in (the order of the parts differs between the languages).
    static func f(_ ko: String, _ args: Any...) -> String {
        var text = t(ko)
        for (index, value) in args.enumerated() { text = text.replacingOccurrences(of: "{\(index)}", with: "\(value)") }
        return text
    }

    /// A lyrics source for the menu: "YouTube Music · 원곡" as "YouTube Music · original". The source itself stays
    /// Korean, since it is saved in the lyrics cache and compared in the lookup.
    static func source(_ source: String) -> String {
        guard language != .ko else { return source }
        for tail in [" · 원곡 검색", " · 원곡", " · 공식 음원"] where source.hasSuffix(tail) {
            return String(source.dropLast(tail.count)) + t(tail)
        }
        return source
    }

    /// A status or message that PearClient keeps in Korean (its statuses are compared, and the tests read them), in
    /// the current language: the text itself, or one with a detail in brackets after it, "가사: 싱크 가사 있음
    /// (LRCLIB · 원곡)" or "브라우저 YouTube Music에 연결됨 (Chrome)". Anything else is shown as it is.
    static func shown(_ text: String) -> String {
        guard language != .ko else { return text }
        if table[text] != nil { return t(text) }
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            let head = String(text[..<open.lowerBound])
            let detail = String(text[open.upperBound...].dropLast())
            if table[head] != nil { return t(head) + " (" + source(detail) + ")" }
        }
        return text
    }

    // Korean: [English, Japanese]
    static let table: [String: [String]] = [
        "알 수 없는 곡": ["Unknown song", "不明な曲"],
        "일시정지됨": ["Paused", "一時停止中"],
        "재생중": ["Now playing", "再生中"],
        "인식할 수 없는 키": ["unknown key", "認識できないキー"],
        "다른 프로그램이 사용 중": ["in use by another program", "他のプログラムが使用中"],
        "단축키를 등록하지 못했습니다: {0}": ["Could not register hotkeys: {0}", "ホットキーを登録できませんでした: {0}"],
        "기본": ["default", "標準"],
        "{0}초 빠르게": ["{0} s earlier", "{0}秒早く"],
        "{0}초 늦게": ["{0} s later", "{0}秒遅く"],
        "지금: {0}": ["Now: {0}", "現在: {0}"],
        "기본으로 되돌리기": ["Reset to default", "標準に戻す"],
        "이 곡의 가사 타이밍을 기본으로 되돌렸습니다": ["This song's lyric timing is back to the default", "この曲の歌詞タイミングを標準に戻しました"],
        "이 곡의 가사를 {0} 표시합니다": ["This song's lyrics now show {0}", "この曲の歌詞を{0}表示します"],
        "모든 곡의 가사 타이밍을 기본으로 되돌렸습니다": ["The lyric timing for all songs is back to the default", "すべての曲の歌詞タイミングを標準に戻しました"],
        "모든 곡의 가사를 {0} 표시합니다": ["Lyrics for all songs now show {0}", "すべての曲の歌詞を{0}表示します"],
        "확인 중…": ["Checking…", "確認中…"],
        "최신 버전": ["Up to date", "最新バージョン"],
        "{0} 설치": ["Install {0}", "{0} をインストール"],
        "설치 중…": ["Installing…", "インストール中…"],
        "업데이트 확인": ["Check for updates", "アップデートを確認"],
        "버전 {0}": ["Version {0}", "バージョン {0}"],
        "새 버전 {0}이 나왔습니다. 메뉴에서 업데이트할 수 있습니다": ["Version {0} is out. You can update from the menu", "新しいバージョン {0} が出ました。メニューからアップデートできます"],
        "최신 버전입니다 ({0})": ["You have the latest version ({0})", "最新バージョンです ({0})"],
        "업데이트를 확인하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오": ["Could not check for updates. Please try again in a moment", "アップデートを確認できませんでした。しばらくしてからもう一度お試しください"],
        "업데이트를 확인하고 있습니다": ["Checking for updates", "アップデートを確認しています"],
        "업데이트를 받고 있습니다 ({0})": ["Downloading the update ({0})", "アップデートをダウンロードしています ({0})"],
        "업데이트하지 못했습니다. 릴리스 페이지를 엽니다": ["Could not update. Opening the release page", "アップデートできませんでした。リリースページを開きます"],
        "업데이트하지 못했습니다. 받은 파일을 엽니다": ["Could not update. Opening the downloaded file", "アップデートできませんでした。ダウンロードしたファイルを開きます"],
        "연결 준비 중": ["Getting ready to connect", "接続の準備中"],
        "브라우저 YouTube Music에 연결됨": ["Connected to YouTube Music in the browser", "ブラウザの YouTube Music に接続済み"],
        "브라우저의 YouTube Music 기다리는 중": ["Waiting for YouTube Music in the browser", "ブラウザの YouTube Music を待機中"],
        "YouTube Music 기다리는 중 (브라우저, Pear Desktop)": ["Waiting for YouTube Music (browser, Pear Desktop)", "YouTube Music を待機中 (ブラウザ、Pear Desktop)"],
        "Pear Desktop 기다리는 중 (API 서버 확인)": ["Waiting for Pear Desktop (check its API server)", "Pear Desktop を待機中 (API サーバーを確認)"],
        "Pear Desktop에서 허용 대기 중": ["Waiting for you to allow it in Pear Desktop", "Pear Desktop での許可を待機中"],
        "Pear Desktop에서 연결 거부됨": ["Connection denied in Pear Desktop", "Pear Desktop で接続が拒否されました"],
        "Pear Desktop에 연결됨": ["Connected to Pear Desktop", "Pear Desktop に接続済み"],
        "Pear Desktop 연결 안 됨 (메뉴에서 연결 요청)": ["Pear Desktop not connected (request a connection from the menu)", "Pear Desktop 未接続 (メニューから接続をリクエスト)"],
        "미리보기 모드": ["Preview mode", "プレビューモード"],
        "Pear Desktop에 연결하지 못했습니다. Pear Desktop이 실행 중이고 API 서버 플러그인이 켜져 있는지 확인해 주십시오": ["Could not connect to Pear Desktop. Please check that Pear Desktop is running and its API Server plugin is on", "Pear Desktop に接続できませんでした。Pear Desktop が起動していて、API サーバーのプラグインがオンになっているか確認してください"],
        "Pear Desktop에 연결 요청 창이 나타났습니다. '허용'을 눌러 주십시오.": ["Pear Desktop is asking whether to allow the connection. Please click 'Allow'.", "Pear Desktop に接続リクエストのウィンドウが表示されました。「許可」を押してください。"],
        "Pear Desktop에서 '허용'을 눌러 주십시오": ["Please click 'Allow' in Pear Desktop", "Pear Desktop で「許可」を押してください"],
        "Pear Desktop에서 연결이 거부되었습니다. 트레이 메뉴의 'Pear Desktop 연결 요청'으로 다시 시도할 수 있습니다.": ["The connection was denied in Pear Desktop. You can try again with 'Request Pear Desktop connection' in the tray menu.", "Pear Desktop で接続が拒否されました。トレイメニューの「Pear Desktop に接続をリクエスト」でもう一度試せます。"],
        "Pear Desktop에서 연결이 거부되었습니다. 메뉴의 'Pear Desktop 연결 요청'으로 다시 시도할 수 있습니다.": ["The connection was denied in Pear Desktop. You can try again with 'Request Pear Desktop connection' in the menu.", "Pear Desktop で接続が拒否されました。メニューの「Pear Desktop に接続をリクエスト」でもう一度試せます。"],
        "Pear Desktop에 연결되었습니다": ["Connected to Pear Desktop", "Pear Desktop に接続しました"],
        "{0} 탭의 주소를 읽을 수 없어서 제목으로 곡을 찾습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 허용할 수 있습니다": ["The address of the {0} tab can't be read, so songs are found by title. You can allow it in System Settings > Privacy & Security > Automation", "{0} のタブのアドレスを読み取れないため、タイトルで曲を探します。システム設定 > プライバシーとセキュリティ > オートメーション で許可できます"],
        "{0} 탭의 주소를 읽기 위해 macOS가 권한을 묻고 있습니다. 화면에 나타난 창에서 '허용'을 눌러 주십시오": ["macOS is asking for permission to read the address of the {0} tab. Please click 'Allow' in the window on screen", "{0} のタブのアドレスを読み取るために、macOS が許可を求めています。画面に表示されたウィンドウで「許可」を押してください"],
        "가사: -": ["Lyrics: -", "歌詞: -"],
        "가사: 찾는 중": ["Lyrics: searching", "歌詞: 検索中"],
        "가사: 앨범 곡이 아니라 찾지 않음": ["Lyrics: not searched (not an album track)", "歌詞: アルバム曲ではないため検索しません"],
        "가사: 연결 실패, 다시 시도 중": ["Lyrics: connection failed, retrying", "歌詞: 接続に失敗、再試行中"],
        "가사: 싱크 가사 있음": ["Lyrics: synced lyrics found", "歌詞: 同期歌詞あり"],
        "가사: 연주곡": ["Lyrics: instrumental", "歌詞: インストゥルメンタル"],
        "가사: 가사 서버에 연결하지 못함": ["Lyrics: could not reach the lyrics server", "歌詞: 歌詞サーバーに接続できません"],
        "가사: 찾지 못함": ["Lyrics: not found", "歌詞: 見つかりません"],
        " · 원곡": [" · original", " · 原曲"],
        " · 원곡 검색": [" · original (search)", " · 原曲検索"],
        " · 공식 음원": [" · official audio", " · 公式音源"],
        "앨범 곡이 아니어서 가사를 표시하지 않습니다": ["Not an album track, so lyrics are not shown", "アルバム曲ではないため、歌詞を表示しません"],
        "가사 서버에 연결하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오": ["Could not reach the lyrics server. Please try again in a moment", "歌詞サーバーに接続できませんでした。しばらくしてからもう一度お試しください"],
        "가사 서버에 연결하지 못했습니다": ["Could not reach the lyrics server", "歌詞サーバーに接続できませんでした"],
        "연주곡입니다": ["This is an instrumental", "インストゥルメンタルです"],
        "이 곡의 싱크 가사를 찾지 못했습니다": ["No synced lyrics were found for this song", "この曲の同期歌詞が見つかりませんでした"],
        "재생 중인 곡이 없습니다": ["Nothing is playing", "再生中の曲がありません"],
        "가사를 다시 찾고 있습니다": ["Searching for the lyrics again", "歌詞を探し直しています"],
        "커버곡을 포함한 모든 곡에서 가사를 표시합니다": ["Lyrics are shown for all songs, covers included", "カバー曲を含むすべての曲で歌詞を表示します"],
        "앨범 곡에서만 가사를 표시합니다": ["Lyrics are shown for album tracks only", "アルバム曲でのみ歌詞を表示します"],
        "가사 표시를 껐습니다": ["Lyrics are turned off", "歌詞の表示をオフにしました"],
        "지금 곡 보기": ["Show current song", "今の曲を表示"],
        "이전 곡": ["Previous song", "前の曲"],
        "재생 / 일시정지": ["Play / Pause", "再生 / 一時停止"],
        "다음 곡": ["Next song", "次の曲"],
        "위젯": ["Widget", "ウィジェット"],
        "곡 정보 계속 표시": ["Always show song info", "曲情報を常に表示"],
        "영상 곡 제목": ["Title for videos", "動画の曲タイトル"],
        "곡 제목": ["Song title", "曲のタイトル"],
        "영상 제목": ["Video title", "動画のタイトル"],
        "표시": ["Show on", "表示"],
        "위치": ["Position", "位置"],
        "크기": ["Size", "サイズ"],
        "투명도": ["Transparency", "透明度"],
        "위젯 끌어서 옮기기": ["Drag the widget", "ウィジェットをドラッグして移動"],
        "Liquid Glass 배경(beta)": ["Liquid Glass background (beta)", "Liquid Glass 背景 (beta)"],
        "Liquid Glass 배경(beta, macOS 26 이상)": ["Liquid Glass background (beta, macOS 26 or later)", "Liquid Glass 背景 (beta、macOS 26 以降)"],
        "사용 안 함": ["Off", "使用しない"],
        "모니터 {0}": ["Monitor {0}", "モニター {0}"],
        "주 모니터": ["main", "メイン"],
        "왼쪽 위": ["Top left", "左上"],
        "가운데 위": ["Top center", "中央上"],
        "오른쪽 위": ["Top right", "右上"],
        "왼쪽 아래": ["Bottom left", "左下"],
        "가운데 아래": ["Bottom center", "中央下"],
        "오른쪽 아래": ["Bottom right", "右下"],
        "직접 옮긴 위치": ["Where you dragged it", "ドラッグした位置"],
        "작게": ["Small", "小"],
        "보통": ["Normal", "標準"],
        "크게": ["Large", "大"],
        "아주 크게": ["Extra large", "特大"],
        "없음": ["None", "なし"],
        "가사": ["Lyrics", "歌詞"],
        "가사 표시": ["Show lyrics", "歌詞を表示"],
        "커버곡 가사 표시(beta)": ["Show lyrics for covers (beta)", "カバー曲の歌詞を表示 (beta)"],
        "가사 다시 찾기": ["Find lyrics again", "歌詞を探し直す"],
        "이 곡 가사 타이밍": ["This song's lyric timing", "この曲の歌詞タイミング"],
        "모든 곡 가사 타이밍": ["All songs' lyric timing", "すべての曲の歌詞タイミング"],
        "재생 앱": ["Player", "再生アプリ"],
        "자동 (브라우저, Pear Desktop)": ["Auto (browser, Pear Desktop)", "自動 (ブラウザ、Pear Desktop)"],
        "브라우저": ["Browser", "ブラウザ"],
        "듣는 중 표시": ["Show \"Listening to\"", "「聴いています」を表示"],
        "GitHub 버튼 표시": ["Show GitHub button", "GitHub ボタンを表示"],
        "언어": ["Language", "言語"],
        "자동": ["Auto", "自動"],
        "Pear Desktop 연결 요청": ["Request Pear Desktop connection", "Pear Desktop に接続をリクエスト"],
        "설정 파일 열기": ["Open config file", "設定ファイルを開く"],
        "설정 다시 불러오기": ["Reload config", "設定を再読み込み"],
        "오류 기록 열기": ["Open error log", "エラーログを開く"],
        "종료": ["Quit", "終了"],
        "듣는 곡을 Discord에 표시합니다": ["The song you are listening to is shown on Discord", "聴いている曲を Discord に表示します"],
        "Discord에 듣는 곡을 표시하지 않습니다": ["The song you are listening to is no longer shown on Discord", "聴いている曲を Discord に表示しません"],
        "브라우저에서 재생하는 YouTube Music을 표시합니다": ["Showing YouTube Music played in the browser", "ブラウザで再生する YouTube Music を表示します"],
        "Pear Desktop에서 재생하는 곡을 표시합니다": ["Showing songs played in Pear Desktop", "Pear Desktop で再生する曲を表示します"],
        "브라우저와 Pear Desktop 중에서 재생 중인 곡을 표시합니다": ["Showing whichever of the browser and Pear Desktop is playing", "ブラウザと Pear Desktop のうち、再生中のほうの曲を表示します"],
        "위젯을 끌어서 원하는 곳에 놓아 주십시오. 다 옮긴 뒤에는 트레이 메뉴의 '위젯 끌어서 옮기기'를 다시 눌러 주십시오.": ["Drag the widget to where you want it. When you are done, click 'Drag the widget' in the tray menu again.", "ウィジェットをドラッグして好きな場所に置いてください。移動が終わったら、トレイメニューの「ウィジェットをドラッグして移動」をもう一度押してください。"],
        "위젯을 끌어서 옮긴 뒤에 메뉴에서 '위젯 끌어서 옮기기'를 다시 눌러 끝내 주십시오": ["Drag the widget, then click 'Drag the widget' in the menu again to finish", "ウィジェットをドラッグして移動したあと、メニューの「ウィジェットをドラッグして移動」をもう一度押して終了してください"],
        "Now Playing Widget이 이미 실행 중입니다.\n작업 표시줄 오른쪽의 트레이 아이콘을 확인해 주십시오.": ["Now Playing Widget is already running.\nPlease look for its icon in the tray at the right end of the taskbar.", "Now Playing Widget はすでに起動しています。\nタスクバー右側のトレイアイコンを確認してください。"],
        "API 서버 설정을 저장했습니다": ["The API server settings were saved", "API サーバーの設定を保存しました"],
        "음악 앱의 API 서버가 응답하지 않습니다": ["The music app's API server is not responding", "音楽アプリの API サーバーが応答しません"],
        "설정을 반영하려면 YouTube Music/Pear Desktop을 다시 시작해야 합니다. 재생 중인 음악이 잠시 멈춥니다.": ["YouTube Music/Pear Desktop has to be restarted for the settings to take effect. The music that is playing will stop for a moment.", "設定を反映するには、YouTube Music/Pear Desktop を再起動する必要があります。再生中の音楽が少しの間止まります。"],
        "음악 앱 다시 시작": ["Restart the music app", "音楽アプリを再起動"],
        "나중에": ["Later", "あとで"],
        "Pear 연결 설정을 적용하지 못했습니다": ["Could not apply the Pear connection settings", "Pear の接続設定を適用できませんでした"],
        "음악 앱을 종료할 수 없습니다. 직접 종료한 뒤에 다시 실행해 주십시오.": ["The music app could not be quit. Please quit it yourself and start it again.", "音楽アプリを終了できません。手動で終了してから、もう一度起動してください。"],
        "음악 앱이 아직 종료되지 않았습니다. 직접 종료한 뒤에 다시 실행해 주십시오.": ["The music app has not quit yet. Please quit it yourself and start it again.", "音楽アプリがまだ終了していません。手動で終了してから、もう一度起動してください。"],
        "YouTube Music/Pear Desktop 설정 파일을 찾지 못했습니다. 음악 앱을 한 번 실행한 뒤에 다시 요청해 주십시오.": ["The YouTube Music/Pear Desktop config file was not found. Please run the music app once and request again.", "YouTube Music/Pear Desktop の設定ファイルが見つかりませんでした。音楽アプリを一度起動してから、もう一度リクエストしてください。"],
        "음악 앱 설정 파일 형식을 확인할 수 없어 변경하지 않았습니다.": ["The music app's config file could not be read, so it was not changed.", "音楽アプリの設定ファイルの形式を確認できないため、変更しませんでした。"],
        "# Now Playing Widget 설정 파일": ["# Now Playing Widget config file", "# Now Playing Widget 設定ファイル"],
        "# 수정한 뒤 트레이 메뉴의 '설정 다시 불러오기'를 누르면 적용됩니다.": ["# Edit it, then click 'Reload config' in the tray menu to apply.", "# 編集したあと、トレイメニューの「設定を再読み込み」を押すと適用されます。"],
        "# 곡을 가져올 곳: auto(브라우저와 Pear Desktop 중 나중에 재생을 시작한 쪽), browser(브라우저의 YouTube Music만), pear(Pear Desktop만)": ["# Where songs come from: auto (whichever of the browser and Pear Desktop started playing last), browser (YouTube Music in the browser only), pear (Pear Desktop only)", "# 曲を取得する場所: auto(ブラウザと Pear Desktop のうち、後から再生を始めたほう)、browser(ブラウザの YouTube Music のみ)、pear(Pear Desktop のみ)"],
        "# 메뉴와 안내 문구의 언어: auto(운영체제의 표시 언어를 따름), ko(한국어), en(English), ja(日本語)": ["# Language of the menu and messages: auto (follows the system's display language), ko (한국어), en (English), ja (日本語)", "# メニューとメッセージの言語: auto(OS の表示言語に従う)、ko(한국어)、en(English)、ja(日本語)"],
        "# Pear Desktop > 확장 > API 서버 [베타]의 호스트/포트와 같아야 합니다.": ["# Has to match the hostname and port under Pear Desktop > Plugins > API Server [Beta].", "# Pear Desktop > プラグイン > APIサーバー(Beta) のホスト名とポートに合わせます。"],
        "# 위젯을 띄울 모니터와 위치. 'widget' 뒤의 숫자는 메뉴의 '모니터 1', '모니터 2'와 같은 번호입니다.": ["# The monitor and position of each widget. The number after 'widget' is the same as 'Monitor 1', 'Monitor 2' in the menu.", "# ウィジェットを表示するモニターと位置。'widget' の後ろの数字は、メニューの「モニター 1」「モニター 2」と同じ番号です。"],
        "# 위치: TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight,": ["# Position: TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight,", "# 位置: TopLeft, TopCenter, TopRight, BottomLeft, BottomCenter, BottomRight,"],
        "#       또는 Custom x y bottom|top (트레이 메뉴의 '위젯 끌어서 옮기기'로 놓은 위치, 모니터 왼쪽과 아래/위 가장자리에서 떨어진 px)": ["#       or Custom x y bottom|top (where 'Drag the widget' in the tray menu left it: px from the monitor's left edge and from its bottom/top edge)", "#       または Custom x y bottom|top (トレイメニューの「ウィジェットをドラッグして移動」で置いた位置。モニターの左端と下端/上端からの px)"],
        "# 위젯마다 표시 여부(false면 꺼 두고 설정만 보관), 크기 배율(1.0 = 기본), 투명도(0 = 불투명, 최대 0.8, 글자까지 함께 투명해짐)": ["# Per widget: shown or not (false keeps it off and only keeps its settings), size multiplier (1.0 = default), transparency (0 = opaque, 0.8 at most, the text becomes transparent too)", "# ウィジェットごとの表示(false ならオフにして設定だけ残す)、サイズ倍率(1.0 = 標準)、透明度(0 = 不透明、最大 0.8、文字も透明になります)"],
        "# 화면 가장자리로부터의 여백(px, Custom이 아닌 위치에 적용)": ["# Margin from the screen edge (px, for positions other than Custom)", "# 画面の端からの余白(px、Custom 以外の位置に適用)"],
        "# 크기 배율 (1.0 = 기본). 위의 widgetNScale이 없는 위젯에 적용됩니다.": ["# Size multiplier (1.0 = default), for widgets without a widgetNScale above.", "# サイズ倍率 (1.0 = 標準)。上の widgetNScale がないウィジェットに適用されます。"],
        "# 곡 카드와 가사 카드의 너비(px, 배율 적용 전)": ["# Width of the song card and the lyrics card (px, before the size multiplier)", "# 曲カードと歌詞カードの幅(px、倍率を掛ける前)"],
        "# 곡이 바뀌었을 때 표시하는 시간(초)": ["# How long the card is shown when the song changes (seconds)", "# 曲が変わったときに表示する時間(秒)"],
        "# 카드 배경의 불투명도 (0.2 ~ 1.0, 글자는 그대로)": ["# Opacity of the card background (0.2 to 1.0, the text is not affected)", "# カードの背景の不透明度 (0.2 〜 1.0、文字はそのまま)"],
        "# true면 사라지지 않고 계속 표시": ["# true keeps the card on screen", "# true なら消えずに表示したままにする"],
        "# 일시정지/재생 시에도 잠깐 표시": ["# Also show the card briefly on pause and resume", "# 一時停止/再生のときにも少しの間表示"],
        "# 영상(MV·커버 등, 앨범 곡 제외)에 영상 제목을 표시 (false면 곡 제목, true면 Pear의 Discord 상태와 같은 영상 제목)": ["# Show the video title for videos (music videos, covers and so on, not album tracks): false = the song title, true = the video title, as in Pear's Discord status", "# 動画(MV、カバーなど。アルバム曲を除く)に動画のタイトルを表示 (false なら曲のタイトル、true なら Pear の Discord ステータスと同じ動画のタイトル)"],
        "# 듣는 곡을 Discord 프로필에 '듣는 중'으로 표시": ["# Show the song you are listening to on your Discord profile as 'Listening to'", "# 聴いている曲を Discord のプロフィールに「聴いています」として表示"],
        "# Discord의 '듣는 중'에 이 앱의 GitHub 페이지로 가는 버튼을 붙임": ["# Add a button to this app's GitHub page to the Discord status", "# Discord の「聴いています」に、このアプリの GitHub ページへのボタンを付ける"],
        "# 가사 (LRCLIB 싱크 가사가 있는 곡만 표시)": ["# Lyrics (shown only for songs with synced lyrics)", "# 歌詞 (同期歌詞のある曲のみ表示)"],
        "# 커버곡 가사 표시(beta). false면 앨범 곡(공식 음원)에서만 가사를 찾아 표시 (커버·MV 등은 찾지 않음)": ["# Show lyrics for covers (beta). false looks up lyrics for album tracks (official audio) only, not for covers, music videos and so on", "# カバー曲の歌詞を表示 (beta)。false ならアルバム曲(公式音源)だけで歌詞を探して表示 (カバー、MV などでは探しません)"],
        "# 다음 줄 가사도 작게 표시": ["# Also show the next lyric line, smaller", "# 次の行の歌詞も小さく表示"],
        "# 모든 곡의 가사 타이밍 보정(ms). +면 가사가 더 빨리, -면 더 늦게 나옵니다. 곡(영상)별 보정은 lyrics-timing.json에 따로 저장하고 이 값에 더합니다.": ["# Lyric timing offset for all songs (ms). + shows lyrics earlier, - later. Per-song (video) offsets are kept in lyrics-timing.json and added to this value.", "# すべての曲の歌詞タイミングの補正(ms)。+ なら歌詞が早く、- なら遅く表示されます。曲(動画)ごとの補正は lyrics-timing.json に別に保存し、この値に加算します。"],
        "# YouTube Music 가사를 먼저 찾고, 실패하면 LRCLIB로 찾기 (Pear Desktop의 YTMusic 가사 제공자와 같은 방식). 메뉴에는 없는 설정입니다.": ["# Try YouTube Music's lyrics first, then LRCLIB (the same way as Pear Desktop's YTMusic lyrics provider). Not in the menu.", "# 最初に YouTube Music の歌詞を探し、失敗したら LRCLIB で探す (Pear Desktop の YTMusic 歌詞プロバイダーと同じ方法)。メニューにはない設定です。"],
        "# YouTube Music 가사 중계 서버 (Pear Desktop이 쓰는 외부 서버)": ["# YouTube Music lyrics relay server (the third-party server Pear Desktop uses)", "# YouTube Music の歌詞の中継サーバー (Pear Desktop が使っている外部サーバー)"],
        "# LRCLIB에 싱크 가사가 없으면 Kugou와 NetEase(网易云音乐)에서도 찾기. 메뉴에는 없는 설정입니다.": ["# Also search Kugou and NetEase (网易云音乐) when LRCLIB has no synced lyrics. Not in the menu.", "# LRCLIB に同期歌詞がなければ、Kugou と NetEase(网易云音乐)でも探す。メニューにはない設定です。"],
        "# 새 버전이 있는지 GitHub에서 확인 (켜 두면 시작할 때와 하루에 한 번, 설치는 메뉴에서 직접 누를 때만 함)": ["# Check GitHub for a new version (at startup and once a day when on; it is installed only when you click it in the menu)", "# 新しいバージョンがあるかを GitHub で確認 (オンにすると起動時と 1 日に 1 回。インストールはメニューで押したときだけ)"],
        "# 단축키 (예: Ctrl+Alt+Right, Ctrl+Shift+F9, 비워두면 사용 안 함)": ["# Hotkeys (for example Ctrl+Alt+Right, Ctrl+Shift+F9; empty = not used)", "# ホットキー (例: Ctrl+Alt+Right, Ctrl+Shift+F9。空にすると使いません)"],
    ]
}
