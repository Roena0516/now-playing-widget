# CLAUDE.md

Now Playing Widget은 YouTube Music에서 재생 중인 곡을 화면 위에 표시하는 오버레이 위젯입니다(Windows와 macOS). 웹 브라우저의 YouTube Music을 기본으로, Pear Desktop(YouTube Music 데스크톱 클라이언트)을 보조로 지원하며, 곡 카드와 싱크 가사를 보여줍니다. 원래는 Euro Truck Simulator 2용 "ETS2 Now Playing"으로 시작했고, 게임과 상관없이 쓸 수 있어서 "Pear Now Playing"(1.9.4까지)이 되었다가, 브라우저 연동을 넣으면서 "Now Playing Widget"으로 바꿨습니다(2026-10-20 사용자 결정). 이름에 YouTube나 YTM을 넣지 않은 것은 상표 때문입니다(Pear Desktop도 같은 이유로 "YouTube Music"에서 이름을 바꿨습니다).

- 저장소: `Roena0516/now-playing-widget`(이전 이름 `pear-now-playing`, GitHub가 예전 주소를 넘겨 줍니다)
- 이전 이름을 그대로 두는 것: 설정·로그·캐시 폴더(`PearNowPlaying`, `PearNowPlaying-macOS`), 맥 번들 ID(`io.github.pdh0128.pear-now-playing.macos`), Pear 인증 ID(`pear-now-playing`, `pear-now-playing-macos`: 바꾸면 Pear가 허용 창을 다시 띄웁니다), Windows 단일 실행 뮤텍스, C# 네임스페이스(`PearNowPlaying`). 업데이트한 사용자의 설정, 권한, 저장된 가사가 이어지게 하기 위해서입니다.
- 사용자 문서: `README.md` (한국어, 합니다체)
- 버전: 올리는 기준과 고칠 곳은 `VERSIONING.md`에 있습니다. Windows는 `src/Program.cs`의 AssemblyVersion(현재 2.0.1.0, User-Agent도 이 값을 읽음)이고, macOS는 `macos/Sources/Models.swift`의 `appVersion`에 적혀 있습니다. `macos/build.sh`는 이 값을 읽어서 Info.plist와 DMG 파일 이름에 넣습니다.
- macOS 버전: `macos/` 폴더에 있습니다(Swift/AppKit, pdh0128의 PR #1에서 시작했습니다). **맥 버전은 웬만하면 Windows 버전을 따라갑니다**(사용자 방침): 메뉴 구성과 이름, 상태·안내 문구, 기본값, 설정 키(단축키 문자열 형식 `Ctrl+Alt+Up` 포함), 로그 파일 이름과 형식, 동작 규칙을 Windows와 같게 맞추고, 플랫폼 차이 때문에 어쩔 수 없을 때만 다르게 합니다. 지금 남아 있는 차이: 설정 파일 형식(Windows `config.ini`, 맥 `config.json`), 여백 기본값과 단위(Windows 40/140px, 맥 Dock과 메뉴 막대를 뺀 영역 기준 24/24pt), 맥의 "Pear Desktop 연결 요청"이 음악 앱의 `config.json`에서 API 서버를 켜 주는 기능(PR #1에서 온 것), 맥 버전에 없는 `https` 설정, Windows의 안내 풍선(맥은 안내 카드로 대신함). 가사를 찾는 순서는 Windows 버전과 똑같이 맞춰 두었습니다. 가사 관련 코드를 고칠 때는 양쪽을 함께 고칩니다(`src/Lyrics.cs` ↔ `LyricsFinder.swift`·`LyricsProvider.swift`, `YtmLyrics.cs` ↔ `YTMusicProvider.swift`, `CoverLyrics.cs` ↔ `CoverLyrics.swift`, `MoreLyrics.cs` ↔ `MoreLyrics.swift`).

## 작업 방식

- 사용자(로에나)는 대화할 때 반말 한국어(임/함체)로 짧고 직접적인 답을 받기를 선호합니다.
- 커밋, 푸시, 릴리스 업로드는 사용자가 직접 합니다. Windows 릴리스 zip에는 `NowPlayingWidget.exe`, `README.md`, `PretendardJP-OFL.txt`를 `NowPlayingWidget/` 폴더째 넣습니다.
- 릴리스 파일 이름에는 버전을 넣습니다: `NowPlayingWidget-Windows-<버전>.zip`, `NowPlayingWidget-macOS-<버전>.dmg`. 1.9.4까지는 `PearNowPlaying-Windows-<버전>.zip`, `PearNowPlaying-macOS-<버전>.dmg`였고, 1.5.2까지는 버전 없는 이름이었습니다. 지난 릴리스의 파일은 바꾸지 않습니다.
- **이름을 바꾼 뒤의 릴리스에는 이전 이름의 파일도 함께 올립니다.** 1.9.4 이하의 업데이터는 `PearNowPlaying-<플랫폼>-<버전>` 파일만 찾기 때문입니다. Windows는 zip 안의 exe 이름까지 `PearNowPlaying.exe`로 찾으므로, 같은 exe를 `PearNowPlaying.exe`라는 이름으로 `PearNowPlaying/` 폴더에 넣은 zip을 따로 만듭니다(README, 폰트 라이선스도 함께). 맥은 DMG 안의 .app 이름을 따지지 않으므로 같은 DMG를 이전 이름으로 복사해서 올립니다. 대부분의 사용자가 새 버전으로 넘어온 뒤에는(몇 번의 릴리스 뒤) 이전 이름 파일을 그만 올려도 됩니다.
- **자동 업데이트**(`src/Updater.cs`, `macos/Sources/Updater.swift`): GitHub `releases/latest`를 시작 30초 뒤와 하루에 한 번 확인합니다(`checkUpdates`). 설치는 메뉴의 "업데이트 설치"를 누를 때만 합니다. 릴리스 파일을 이름(`NowPlayingWidget-<플랫폼>-<버전>`, 없으면 이전 이름 `PearNowPlaying-<플랫폼>-<버전>`)으로 찾고, API의 `digest`(SHA-256)로 검증하며, digest가 없으면 업데이트로 제안하지 않습니다. Windows는 zip을 풀어(`NowPlayingWidget.exe`, 없으면 `PearNowPlaying.exe`) 실행 중인 exe를 `.old`로 옮기고 새 exe를 같은 파일 이름으로 넣은 뒤 `--wait-for <pid>`로 재실행합니다(단일 인스턴스 검사를 통과하기 위함). 사용자가 만든 바로 가기가 끊어지지 않도록 exe 파일 이름은 바꾸지 않습니다. 맥은 DMG를 `-nobrowse`로 마운트해서 `codesign --verify`, 번들 ID, 버전을 확인한 뒤 번들을 교체하고(설치된 앱 이름이 `Pear Now Playing.app`이면 같은 폴더의 `Now Playing Widget.app`으로 바꿔서 넣음), 프로세스가 끝나면 `open`으로 다시 실행합니다. 실패하면 되돌리고 릴리스 페이지나 받은 DMG를 엽니다. 맥 권한은 2026-10-19에 이 Mac(macOS 26.4, 관리자, Chrome 격리 표시가 있고 허용된 상태)에서 실험해서 문제없음을 확인했습니다. 테스트는 `macos/Tests/mock_update.py`(가짜 GitHub)입니다.
- macOS 릴리스는 `./macos/build.sh --universal --dmg`로 만든 `macos/build/NowPlayingWidget-macOS-<버전>.dmg`를 올립니다(arm64+x86_64). 앱은 `macos/build/Now Playing Widget.app`, 실행 파일은 `Contents/MacOS/NowPlayingWidget`입니다. zip은 올리지 않습니다. 앱은 ad-hoc 서명만 하고 공증은 받지 않습니다.
- DMG 창의 모양(창 크기, 아이콘 위치, 배경)은 `macos/dmg-settings.py`에 있고, `dmgbuild`(1.6.7로 고정, 처음 `--dmg`로 빌드할 때 `macos/build/dmg-venv`에 설치됨)가 Finder 없이 만듭니다. 앱 아이콘(`macos/Resources/AppIcon.icns`)과 DMG 배경(`macos/Resources/dmg-background.tiff`)은 `xcrun swift macos/Tools/make-art.swift`로 다시 그릴 수 있으며, 결과 파일은 커밋되어 있습니다. 배경의 아이콘 위치를 바꾸면 `dmg-settings.py`의 `icon_locations`도 함께 바꿉니다.
- 커밋 메시지는 한국어로 짧게 씁니다(예: "트레이 가사 다시 찾기에 결과 표시").
- 릴리스 본문은 합니다체로 씁니다.
- 루트에 있는 `NowPlayingWidget.exe`, `PearNowPlaying.exe`, `_capture/`, `*.zip`은 커밋하지 않습니다(`.gitignore`).
- 실행 로그는 `%AppData%\PearNowPlaying\error.log`(맥은 `~/Library/Application Support/PearNowPlaying-macOS/error.log`, `Log.swift`), 설정은 `%AppData%\PearNowPlaying\config.ini`(맥은 같은 폴더의 `config.json`)에 있습니다. 맥 로그에는 연결이 끊긴 이유(WebSocket 종료 코드, HTTP 상태, 오류 도메인과 코드)도 남습니다. 가사가 표시되지 않는다는 제보를 받으면 로그부터 확인합니다. 가사를 검색하는 단계마다 INFO 줄이 기록됩니다.

## 문서 작성 규칙

- `README.md`, `macos/README.md`, `macos/ORIGINAL-BEHAVIOR-AUDIT.ko.md`, `VERSIONING.md`, 이 `CLAUDE.md`를 포함한 모든 문서는 합니다체로 씁니다.
- 문서를 쓸 때는 사용자가 제공한 한국어 작성 지침(`~/Desktop/fluent-korean-not-coding.md`)을 따릅니다. 예를 들어 의미가 있는 문장 성분과 조사를 생략하지 않고, 문장은 서술어와 종결어미로 끝내며, 비유적인 어휘와 엠대시(—)는 피합니다.
- 이 지침은 프로젝트 문서에만 적용합니다. 사용자와 대화할 때는 위의 "작업 방식"에 적은 대로 반말(임/함체)을 사용합니다.
- 앱의 UI 문자열(안내 카드, 알림, 대화상자, 권한 설명)도 문서와 같이 합니다체로 씁니다(사용자 방침, 2026-10-20, 그전에는 해요체였습니다). 사용자에게 무언가를 하도록 요청하는 문장은 "'허용'을 눌러 주십시오"처럼 "~해 주십시오"로 끝냅니다. 메뉴 항목과 상태 줄("연결 준비 중", "가사: 찾는 중")처럼 명사로 끝나는 표시는 그대로 둡니다. DMG 배경에 들어가는 설치 안내 문구도 합니다체입니다. 코드 주석과 로그는 영어로 씁니다. 문서에서 UI 문구를 인용할 때는 실제 문구를 그대로 옮깁니다.

## 빌드

macOS: `./macos/build.sh`로 빌드합니다(Xcode Command Line Tools가 필요합니다). 테스트는 앱 실행 파일(`macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget`)에 `--self-test`, `--lyrics-tests`, `--ytmusic-tests`를 붙여 실행하고, `python3 macos/Tests/mock_pear.py`, `mock_update.py`, `mock_discord.py`도 실행합니다. 실제 곡으로 확인할 때는 `--lookup <영상 ID>`(가사 찾기 과정)와 `--browser-probe [초]`(브라우저 연동)를 씁니다. `--lyrics-tests`에 들어 있는 커버곡 케이스(`CoverTests.swift`)는 C# 코드가 낸 결과를 그대로 기대값으로 넣은 것이므로, `CoverLyrics.cs`를 바꾸면 이 기대값도 함께 갱신합니다. GitHub Actions의 `macOS` 워크플로가 같은 테스트를 실행합니다.

Windows:

- C# 7.3, .NET Framework 4.8, WinForms를 사용합니다. 외부 패키지는 사용하지 않습니다(JSON은 `System.Web.Extensions`의 JavaScriptSerializer로 처리합니다).
- Windows에서는 `dotnet build -c Release`로 빌드합니다(`NowPlayingWidget.csproj`, SDK 스타일 net48, 결과는 `NowPlayingWidget.exe`).
- Linux에서는 `sh build.sh`를 실행하면 `bin/NowPlayingWidget.exe`가 만들어집니다. dotnet SDK에 들어 있는 Roslyn `csc.dll`에 Mono 참조 어셈블리(`/usr/lib/mono/4.8-api`)를 붙여서 빌드합니다. macOS에서도 같은 방식으로 빌드할 수 있습니다(Homebrew Mono의 참조 어셈블리는 `/opt/homebrew/lib/mono/4.8-api`에 있습니다).
- 폰트(Pretendard JP Regular/Medium)와 글리프 커버리지 파일은 EmbeddedResource이며, LogicalName은 파일 이름과 같습니다. csproj와 build.sh 양쪽을 함께 맞춰야 합니다.
- C# 7.3의 제약: `?.`는 사용할 수 있지만, switch 식, `using` 선언, nullable 참조 형식, 범위 연산자는 사용할 수 없습니다.
- 저장소에는 Windows 버전의 테스트 프로젝트가 없습니다. 지금까지는 저장소 밖에서 `src/*.cs`(Program.cs 제외)를 테스트 파일과 함께 컴파일하고, LRCLIB·YouTube Music·Pear를 흉내 내는 로컬 모의 서버를 띄워서 Mono로 실행했습니다. 클래스 대부분이 `internal`이므로 exe를 참조하는 방식으로는 테스트할 수 없습니다.

## 구조

| 파일 | 내용 |
|---|---|
| `src/Program.cs` | 진입점, 단일 인스턴스 확인, 버전 정보 |
| `docs/*.gif` | README의 예시 화면입니다. 맥 앱의 `--render-demo <폴더>`(`macos/Sources/DemoRenderer.swift`)가 앱의 렌더러로 프레임을 그리고, `python3 macos/Tools/make-gifs.py`(Pillow 필요)가 GIF로 묶습니다. 예시 곡은 코가네 랑의 「호랑풍류가」 커버(iAoU1UGPoXc, 사용자 선택)이고, 앨범 아트는 그 영상의 썸네일(`make-gifs.py`가 받아서 넘김, 사용자 요청)입니다. 가사 줄은 위젯을 설명하는 예시 문장입니다. 실제 가사는 저작권 때문에 넣지 않습니다. |
| `src/BrowserSource.cs` | 브라우저의 YouTube Music에서 곡을 가져옵니다(아래 "브라우저 연동"). SMTC와 UI Automation을 리플렉션으로 부르는 래퍼(`WinRt`, `Smtc`, `BrowserWindows`), `--browser-probe` 모드(`BrowserProbe`)도 이 파일에 있습니다. 맥은 `BrowserSource.swift`와 `macos/Helper/NowPlaying.m`입니다. |
| `src/DiscordPresence.cs` | Discord "듣는 중" 표시(아래 "Discord" 항목). 맥은 `DiscordPresence.swift`입니다. |
| `src/PearClient.cs` | 보여 줄 곡의 소스(Pear 또는 브라우저)를 고르고(`HandleMessage`, `PlayerState`), Pear API 서버 플러그인과 통신합니다: `POST /auth/{id}`로 토큰 발급(처음 한 번은 Pear가 허용 창을 띄웁니다), WebSocket `/api/v1/ws`, `POST /api/v1/next`·`previous`·`toggle-play`, `GET /api/v1/queue/next`(다음 곡). `SongInfo.MediaType`은 AUDIO / ORIGINAL_MUSIC_VIDEO / USER_GENERATED_CONTENT / PODCAST_EPISODE / OTHER_VIDEO 중 하나이며, 재생목록(큐)에서 가져온 곡은 UNKNOWN입니다. |
| `src/OverlayWindow.cs` | 클릭이 통과하는 항상 위 레이어드 창(`UpdateLayeredWindow`), 페이드·이동 애니메이션. `Interactive`를 켜면 클릭 통과(`WS_EX_TRANSPARENT`)를 끄고 끌기 이벤트를 보냅니다 |
| `src/Placement.cs` | 끌어서 놓은 위젯의 모니터와 위치(`Custom`) 계산(순수 함수). 맥은 `NativePlacement.fromDrop` |
| `src/CardRenderer.cs` | 곡 카드 그리기, 긴 제목 마퀴 |
| `src/LyricsView.cs` | 가사 목록 스크롤, 줄 전환 애니메이션 |
| `src/Lyrics.cs` | `LyricsProvider`: 가사를 찾는 전체 순서, 캐시, 미리 받기, LRCLIB 검색, LRC 파서 |
| `src/YtmLyrics.cs` | YouTube Music: 곡 정보, 가사(프록시 경유), 공식 음원 찾기, 영상 설명란 |
| `src/MoreLyrics.cs` | Kugou·NetEase 가사 검색(LRCLIB에 없을 때), 후보 대조(`Choose`), 작사·작곡 표기 줄 지우기(`CleanLines`) |
| `src/CoverLyrics.cs` | 커버곡 판별, 설명란에서 원곡 링크 고르기, 제목에서 곡명·원곡자 추출, 편곡·리믹스 거르기(대부분 순수 함수) |
| `src/TrayApp.cs` | 트레이 메뉴(위젯·가사 하위 메뉴, 위젯별 위치·크기·투명도), 곡 카드·정보 카드의 표시 시점, 위젯 끌어서 옮기기 모드, 가사 재시도 루프, 다음 곡 미리 받기 |
| `src/Config.cs` | config.ini 읽기/쓰기, 예전 ETS2NowPlaying 설정 이전(`MigrateOldConfig`), 토큰 저장 |
| `src/Hotkeys.cs`, `src/Native.cs`, `src/Theme.cs` | 전역 단축키, Win32 P/Invoke, 색 토큰과 폰트 로딩 |

## 브라우저 연동 (`BrowserSource`)

웹 브라우저에서 재생하는 YouTube Music도 곡 소스로 씁니다(사용자 방침, 2026-10-20: 브라우저를 기본으로, Pear는 보조로 둡니다). 브라우저 확장 프로그램은 설치하지 않는 방식으로 정했습니다.

- 설정 `source`(Windows config.ini, 맥 config.json)는 `auto`(기본), `browser`, `pear` 중 하나이며, 메뉴의 "재생 앱"에서 바꿉니다. `auto`에서는 두 소스를 모두 받고, 나중에 재생을 시작한 쪽의 곡을 보여 줍니다(`PearClient.HandleMessage`/`handle`): 재생을 시작하거나 새 곡을 재생한 소스가 넘겨받고, 보여 주던 소스가 일시정지했거나 곡이 없을 때는 재생 중인 소스가 넘겨받습니다. 소스마다 곡과 위치(`PlayerState`, 뒤로 가는 위치의 보류 포함)를 따로 둡니다. 브라우저 소스는 Pear의 WebSocket 메시지 형식(`VIDEO_CHANGED`, `PLAYER_STATE_CHANGED`, `POSITION_CHANGED`)으로 보내므로 가사 찾기, 미리 받기, 카드 표시는 Pear일 때와 같은 코드를 씁니다.
- 곡 정보: 탭에서 videoId를 알면 YouTube Music `next`(가사 조회의 첫 요청과 같고, 메모됩니다)의 재생목록 항목으로 제목, 아티스트, 길이, 미디어 타입(`musicVideoType` → Pear의 MediaType), 앨범아트(`TrackInfo.Thumbnail`, 앨범 표지는 544px로 요청)를 채웁니다. 브라우저가 알려 주는 제목이 항목 제목의 한쪽 반이면(「アイドル - Idol」의 "Idol") Pear처럼 그 제목을 씁니다. 아티스트는 YouTube Music 쪽을 씁니다. 브라우저가 주는 아티스트는 YouTube Music 화면 언어로 바뀌어 있기 때문입니다(실제 사례: "요아소비").
- 맥: macOS의 "지금 재생 중" 정보(MediaRemote)를 `/usr/bin/perl`이 불러오는 `libnowplaying.dylib`(`macos/Helper/NowPlaying.m`, `build.sh`가 `Contents/Frameworks`에 넣음)이 1초마다 JSON 한 줄로 알려 줍니다. macOS 15.4부터 MediaRemote는 Apple이 허용한 프로세스에만 답하고, 앱이 직접 부르면 빈 값이 옵니다(이 Mac, macOS 26.4에서 확인). 라이브러리는 격리 표시를 피하려고 `~/Library/Application Support/PearNowPlaying-macOS/helper/`에 복사해서 씁니다. 재생 중인 앱이 브라우저일 때만 `osascript`로 그 브라우저의 `music.youtube.com` 탭 주소와 제목을 읽습니다. 걸러내는 조건이 스크립트 안(`whose URL starts with`)에 있어서 다른 탭의 주소는 브라우저 밖으로 나오지 않습니다. 처음 읽을 때 "자동화" 권한을 묻습니다(`NSAppleEventsUsageDescription`). 권한 창이 떠 있는 동안 읽기가 시간 초과(-1712)로 끝나므로, 이번 실행에서 아직 한 번도 읽지 못한 브라우저에서 시간 초과가 나면 위젯에 "'허용'을 눌러 주십시오" 안내 카드를 한 번 띄웁니다. 권한 창은 다른 화면에 떠서 놓치기 쉽습니다(2026-10-20 실제로 놓쳤음). 다시 빌드해서 ad-hoc 서명이 바뀐 앱도 권한을 다시 묻지 않았습니다. `NSAppleScript`는 쓰지 않습니다. 백그라운드 스레드에서 실행하면 브라우저의 응답을 받지 못하고 멈췄고, 메인 스레드에서는 응답을 기다리는 0.2–0.4초 동안 위젯이 멈추기 때문입니다. 스크립트의 구분자는 tell 블록 밖에서 `character id 9`로 정합니다. tell 블록 안의 `tab`은 Chrome의 탭 클래스로 해석되어 "tab"이라는 글자가 들어갑니다. 재생/일시정지, 다음 곡, 이전 곡은 MediaRemote 명령으로 보냅니다. Chromium 계열(Chrome, Edge, Brave, Arc, Vivaldi, Opera, Whale)과 Safari의 탭을 읽고, Firefox처럼 탭을 읽을 수 없거나 권한을 거부한 브라우저는 제목으로 찾습니다.
- Windows: SMTC(`Windows.Media.Control`, Windows 10 1809 이상)를 리플렉션으로 읽습니다. 빌드에 Windows.winmd가 없어서(Mono 참조 어셈블리로도 빌드하므로) PowerShell 5.1과 같은 방식으로 실행할 때 타입을 이름으로 찾습니다. 재생 정보의 위치는 페이지가 위치를 알릴 때만 바뀝니다. YouTube Music 웹은 재생 시작과 탐색 때만 `setPositionState`를 부르므로(2026-10-20 Chrome에서 측정), 마지막 위치에 흐른 시간을 더해서 씁니다. 맥의 MediaRemote도 같습니다. 탭은 UI Automation(`System.Windows.Automation`, 실행할 때 불러옴)으로 읽습니다. 창 제목에 "YouTube Music"이 있는 창(YouTube Music 탭이 앞에 있는 창)에서만 주소창을 읽고(제목이 바뀐 뒤 5초 동안은 매번 읽음), 그 밖에는 탭 줄의 탭 이름만 읽습니다. 탭 이름에는 원제가 있어서("アイドル - Idol | YouTube Music") 검색에 씁니다. 재생 제어는 SMTC 명령으로 보냅니다. 2026-10-20 기준으로 Windows 쪽은 빌드와 Mono 테스트만 했고, 실제 실행은 사용자가 Windows를 쓸 수 있는 2026-10-23에 확인할 예정입니다. 확인할 때는 `NowPlayingWidget.exe --browser-probe [초]`를 실행합니다. SMTC 값, 브라우저 창 제목, 주소창과 탭 이름, 보내는 메시지를 콘솔과 `%AppData%\PearNowPlaying\browser-probe.log`에 남깁니다. 맥은 `--browser-probe [초]`로 같은 내용을 출력합니다.
- 2026-10-20 Windows 실측(`--browser-probe`): Chrome의 SMTC 앱 ID는 `chrome.exe`입니다. 탭이나 플레이어가 음소거되어 있으면 Chrome이 SMTC 세션을 만들지 않아서 아무것도 잡히지 않습니다. 위치는 재생 시작(0초, 약 3초)과 탐색 때만 갱신되고, 그 사이 계산값이 실제와 맞았습니다. 탭 줄의 탭 이름에는 "- 오디오 재생" 같은 상태가 붙습니다. 곡이 바뀔 때 Chrome이 SMTC 정보를 1초쯤 비우므로, 재생 정보가 비거나 YouTube Music 탭이 보이지 않는 상태가 3초 넘게 이어질 때만 멈춘 것으로 봅니다(`Missing`/`missing`). 그 전에는 곡이 바뀔 때마다 잠깐 "일시정지"로 보였습니다. 이미 알아낸 곡을 SMTC가 같은 제목으로 알려 주는 동안에는 탭이 다른 탭 뒤로 가도 그 곡을 유지하고 다시 검색하지 않습니다(`Shown`/`shown`).
- 다른 사이트와 구분: 브라우저에 YouTube Music 탭이 없으면 다른 사이트의 영상으로 보고 무시합니다. 탭 제목과 브라우저가 알려 주는 제목이 3초 넘게 다르면, 앨범 정보가 있는 곡은 YouTube Music 곡으로 보고 제목으로 찾고, 앨범 정보가 없으면 다른 사이트로 봅니다. 탭이 다른 곡의 주소와 제목을 그대로 둔 채 이 곡을 재생한 적이 있습니다(2026-10-20 맥, 앨범 링크로 연 탭의 주소창은 "Epilogue", 재생은 「ハルジオン」). 주소의 영상을 조회한 제목이 재생 중인 곡과 다를 때도(주소를 곡이 바뀌기 전에 읽은 경우) 3초 동안 기다린 뒤 제목으로 찾습니다.
- 제목으로 찾기(`videoByTitle`/`VideoByTitle`): 탭의 재생목록에서 제목과 길이(±3초)가 맞는 항목을 찾고, 없으면 YouTube 검색(`www.youtube.com/youtubei/v1/search`, WEB, `hl=ja`)의 결과를 `PickVideo`/`pickVideo`로 고릅니다. 길이가 ±2초 안이고 제목이 똑같은 결과(커버 영상 자체), 아티스트 채널이거나 공식 아티스트 배지(`BADGE_STYLE_TYPE_VERIFIED_ARTIST`) 또는 "- Topic" 채널이면서 제목에 곡 이름(`TitleNames`)이 들어 있는 결과를 차례로 받습니다. 그것도 없으면 길이가 ±1초인 공식 채널 결과가 하나뿐일 때만 받습니다(현지화된 "요아소비 Idol"만 알 때). 같은 길이의 팬 업로드는 받지 않습니다(실제 사례: 3:46인 「アイドル」 영상이 공식 MV 말고도 있었음). 익명 YouTube Music 검색은 한국에서 팟캐스트만 돌려줘서 쓰지 않습니다. 끝내 못 찾으면 videoId 없이(미디어 타입 UNKNOWN) 제목과 아티스트로만 가사를 찾습니다.
- 다음 곡(`NextSong`/`nextSong`): 탭 주소의 `list`(앨범, 재생목록)로 YouTube Music `next`를 불러 재생목록 순서에서 다음 곡을 고릅니다(`QueueAfter`, 목록은 메모). 익명 응답에서는 앨범 항목이 뮤직비디오 ID로 오고(이 지역에서는 "Video blocked in country", 제목 없음) 실제로 재생되는 공식 음원 ID는 항목의 `watchEndpoint.params`(base64 protobuf) 안에 있어서 `Counterpart`로 꺼냅니다. 브라우저의 실제 재생 대기열은 읽을 수 없으므로, 셔플이나 라디오에서는 추정이 틀립니다. 한 번 틀린 목록은 다시 맞을 때까지 추정만 하고 미리 받기는 하지 않습니다(사용자는 셔플을 자주 씁니다). 라디오(`RDAMVM…`)는 익명으로 부르면 곡 하나만 옵니다. 사용자 재생목록(`PL…`)은 익명 응답이 앞쪽 32곡 정도만 주므로, 지금 곡이 그 밖에 있으면 다음 곡을 추정하지 않습니다(2026-10-20 실측, 셔플 중이었으므로 추정이 맞을 수도 없었습니다).

## Discord "듣는 중" 표시 (`DiscordPresence`)

- 듣는 곡을 Discord 프로필에 "듣는 중"(Rich Presence, 활동 종류 2)으로 표시합니다(2026-10-20 사용자 요청). 브라우저의 곡과 Pear의 곡을 모두 표시합니다(사용자 방침, 2026-10-20: 처음에는 Pear 곡을 뺐지만 위젯의 설정이 켜져 있으면 Pear 곡도 표시하기로 바꿈). 기본값은 꺼짐이며(`discordPresence`), 메뉴의 "Discord" 하위 메뉴에서 켭니다. GitHub 페이지로 가는 "Now Playing Widget" 버튼은 `discordButton`(기본 켜짐)으로 끄고 켭니다.
- Discord 앱의 로컬 IPC로 보냅니다: Windows는 파이프 `\\.\pipe\discord-ipc-N`, 맥은 `$TMPDIR/discord-ipc-N` 소켓입니다. 프레임은 opcode와 길이(각각 리틀 엔디언 4바이트) 뒤에 JSON이 오는 형식이고, 핸드셰이크(opcode 0, `client_id`)를 한 뒤 `SET_ACTIVITY`를 보냅니다. 애플리케이션 ID는 `1562020013953515553`(사용자가 Developer Portal에서 만든 앱)입니다. Discord가 돌려주는 응답은 읽어서 버립니다. 읽지 않으면 버퍼가 차서 쓰기가 멈추기 때문입니다.
- 내용: 곡 제목(카드에 보이는 제목, `details`), 아티스트(`state`), 앨범아트 주소(`large_image`, Discord가 직접 받아 갑니다), 시작·끝 시각(진행 막대), 버튼입니다. `status_display_type` 2로 멤버 목록에도 곡 제목이 보입니다. 문자열은 2–128자여야 해서 짧으면 U+2800으로 채웁니다. 일시정지하면 활동을 지웁니다(`activity: null`).
- Discord의 요청 제한(20초에 5번 정도) 때문에, 곡이 바뀌거나 재생 상태가 바뀌거나 탐색해서 시작 시각이 3초 넘게 달라질 때만 보내고, 보내는 사이에 4초를 둡니다. 위치는 1초마다 다시 계산하지만 같은 내용이면 보내지 않습니다. Discord가 꺼져 있으면 15초마다 다시 연결해 봅니다.
- Discord 데스크톱 앱이 있어야 합니다. 브라우저에서 여는 Discord(웹)에는 로컬 IPC가 없어서 표시할 방법이 없습니다(Pear의 Discord 플러그인도 같습니다).
- 테스트: 맥은 `macos/Tests/mock_discord.py`(가짜 Discord 소켓, 앱의 `--discord-test <폴더>`)입니다. Windows는 Mono 테스트로 JSON만 확인했고, 파이프 연결은 Windows에서 확인해야 합니다.

## 가사를 찾는 순서 (`LyricsProvider.Find`)

1. 메모리 캐시, 미리 받아 둔 결과(videoId 기준), 디스크 캐시(`LyricsDiskCache`)를 차례로 확인합니다.
2. **YouTube Music**에서 찾습니다(`ytmLyrics=true`이고 서킷 브레이커가 대기 중이 아닐 때만 찾습니다).
   - 먼저 그 영상 자체의 싱크 가사를 찾습니다.
   - 없으면 같은 아티스트의 앨범에서 공식 음원(ATV)을 찾아 그 가사를 사용합니다(출처는 "YouTube Music · 공식 음원"으로 표시합니다).
3. **커버곡이면 원곡의 가사**를 찾습니다(`CoverLyrics.MayBeCover`).
   - `FromOriginal`: 설명란 링크 중 원곡 후보를 고른 뒤, 원곡의 YTM 가사, 원곡의 공식 음원 가사, 원곡 제목으로 검색한 LRCLIB 가사를 차례로 시도합니다.
   - 원곡 링크 확인과 원곡 정보(제목, 아티스트, 길이)는 `youtube.com`과 `music.youtube.com`에 직접 묻고, 가사 중계 서버가 필요한 것은 원곡의 YouTube Music 가사와 공식 음원 가사뿐입니다. 그래서 중계 서버가 서킷 브레이커로 쉬는 중이거나 원곡 조회에서 실패해도(502 등) 이 단계는 그대로 진행하고, 원곡의 YouTube Music 가사만 건너뛴 채 원곡 제목으로 LRCLIB를 찾습니다. 1.9.1까지는 중계 서버가 쉬면 이 단계를 통째로 건너뛰어서, 2026-10-19 밤부터 중계 서버가 502만 돌려주는 동안 「Booo!」 커버 같은 곡이 커버 제목으로만 찾다가 가사 없음으로 끝났습니다.
   - 쓸 수 있는 링크가 없으면(링크가 없거나 모두 다른 곡이면) 곡명(`GuessOriginal`)으로 YouTube를 검색해서 원곡 영상을 찾습니다(`SearchOriginal`, `CoverLyrics.PickOriginal`, 2026-10-20 사용자 요청). 공식 아티스트 배지나 "- Topic" 채널의 영상 중 제목에 곡명이 있고, 커버·歌ってみた·편곡 표시가 없으며, 커버 업로더의 것이 아니고, 커버와 길이가 30초 안인 것만 후보로 봅니다. 후보의 아티스트가 여럿이면 길이가 10초 안인 아티스트가 하나뿐일 때만 고릅니다(「プロポーズ」: なとり와 内緒のピアス, 「メランコリック」: Junky와 MORE MORE JUMP!는 고르지 않음). 찾은 영상은 "원곡" 표시가 있는 링크처럼 처리하고(`TryOriginal`), 길이가 10초 넘게 다르면 그 영상의 아티스트(제목에 적힌 아티스트 포함)로만 LRCLIB를 찾습니다. 실제 사례: Enel의 「君の知らない物語」 커버(338초)는 설명란에 원곡 링크가 없고 원곡자 줄(`music：ryo(supercell) 様（https://…）`)을 잘못 읽어서 못 찾았는데, 검색으로 supercell 공식 MV(356초)를 찾아 "supercell"로 찾게 되었습니다.
   - 그래도 없으면 `FromSearch`를 사용합니다: 제목과 설명란에서 곡명과 원곡자를 추정(`GuessOriginal`)해서 LRCLIB에서 검색합니다.
4. **LRCLIB**에서 찾습니다(`FindLrclib`): `/api/get`(정확한 제목·아티스트·앨범·길이로 조회하며, 다른 제목으로 최대 4번 시도합니다. "心を刺す言葉だけ - Only Words"처럼 둘로 나뉜 제목은 양쪽 반도 각각 시도합니다(`TitleHalves`). LRCLIB에는 영어 제목으로만 있는 곡이 있습니다), `/api/search`, `q=` 검색(최대 3번)을 차례로 시도하고, 마지막으로 제목이 같고 길이가 맞는 결과를 고릅니다(기본 허용 오차는 ±3초이고, 커버곡은 ±10초입니다).
   - 앨범 곡(AUDIO)의 제목을 Pear가 번역·로마자로만 주면(`kanade tomosu sora nekobolo version`), YouTube Music 조회에서 이미 받은 재생목록 제목의 원제(`カナデトモスソラ　ねこぼーろver.`, `CoverLyrics.OriginalTitle`)를 대체 제목으로 붙여서 LRCLIB를 찾습니다(`WithOriginalTitle`). 마지막 `q=` 검색은 부른 사람만 밝히는 "○○ver."를 뗀 제목(`WithoutVersionTag`, 편곡 표기가 있으면 떼지 않음)으로 합니다. 아티스트가 로마자여도 Pear 태그의 원래 이름(ササノマリイ)이 원제와 함께 맞으면 받습니다.
   - 싱크 가사의 마지막 줄이 그 항목의 등록 길이나 지금 곡 길이보다 5초 넘게 뒤에 있으면 그 항목은 쓰지 않습니다(`LyricsFit`/`LyricRecord.fits`, get·검색·제목 대조 모두). LRCLIB에는 길이를 잘못 적은 항목이 있습니다(실제 사례: 등록 길이 232초인 "Bad Apple!! feat.nomico"에 305초까지 이어지는 원곡 가사가 들어 있어서 222초짜리 커버에 붙음).
   - 제목 대조(`PickByTitle`/`pickByTitle`, 아티스트가 다른 결과)는 제목에 붙은 【태그】와 `PV`/`MV`를 떼고 비교합니다. 후보 중에서는 같은 타이밍(줄 수, 첫 줄, 마지막 줄)으로 가장 많이 등록된 가사를 고릅니다(많이 알려진 버전이 여러 번 올라와 있기 때문입니다). 설명란이나 제목에 원곡자가 적힌 커버는, 후보끼리 가사가 서로 다르면 3개 이상 똑같이 등록되어 있고 다른 후보보다 많을 때만 받습니다. 후보가 한 종류뿐이면 그대로 받습니다(원곡자 표기가 다를 뿐인 경우: ryo / supercell). 등록 횟수보다 먼저, 가사에 곡 제목이 들어 있는 후보가 있으면 그 후보들만 봅니다. LRCLIB에는 같은 앨범의 다른 곡 가사가 이 제목으로 여러 번 올라간 경우가 있습니다(「チュルリラ・チュルリラ・ダッダッダ!」 제목에 「トンデモワンダーズ」 가사 4개).
   - 커버의 원곡 링크로 LRCLIB를 찾을 때, 원곡 영상 제목에 곡명과 나란히 적힌 아티스트(`チュルリラ…！ - 和田たけあき(くらげP)`, `ArtistsInTitle`)를 태그로 넘깁니다. YouTube Music은 채널의 로마자 이름(`WADATAKEAKI KurageP`)을 주는데 LRCLIB에는 제목의 이름으로 올라가 있기 때문입니다.
   - 싱크 가사가 있는 후보가 없을 때만 "연주곡"(`instrumental`) 표시를 봅니다. 이때는 피처링 표기만 빼고 제목이 같은 항목(`SameVersion`, 리믹스·버전 표기까지 같아야 함)의 표시만 인정하고, 같은 버전 항목 중 일반 가사가 있는 것이 하나라도 있으면 연주곡으로 보지 않습니다. 예전에는 "PUPA (Endorfin. Remix)"(일반 가사만 있음)가 길이가 비슷한 uma Remix와 원곡 확장판의 연주곡 표시를 받아 "연주곡"으로 나왔습니다.
   - 아티스트 대조(`Pick`)에서 Pear의 태그도 아티스트의 다른 표기로 보지만, 곡 제목이나 앨범 이름과 같은 태그는 뺍니다(Pear는 태그에 제목과 앨범을 넣습니다). 태그로만 아티스트가 맞은 결과는 곡 제목도 맞아야 받습니다. 예전에는 BlackY의 "LAMIA"(태그에 LAMIA)에 래퍼 Lamia의 다른 곡 가사가 붙었습니다.
5. **Kugou, NetEase**(`MoreLyrics`, `moreLyrics=true`일 때): `FindLrclib`을 부르던 곳은 모두 `FindSynced`/`findSynced`를 거칩니다. LRCLIB에 싱크 가사가 없거나(연주곡 표시는 그대로 씀) LRCLIB가 요청 제한(429, `LyricsResult.RateLimited`, 맥은 domain "LRCLIB" code 429 오류)으로 실패하면 Kugou(`lyrics.kugou.com/search?keyword=아티스트 - 제목&duration=ms` → `/download`, base64 LRC), 그다음 NetEase(`music.163.com/api/cloudsearch/pc` → `/api/song/lyric`)에 묻습니다. 2026-10-19에 익명으로 확인한 경로입니다(NetEase의 `/api/search/get/web`은 응답이 암호화되었고 `/api/search/pc`는 휴대폰 인증을 요구합니다. Kugou는 아티스트 없이 제목만으로는 결과를 주지 않습니다. Musixmatch 데스크톱 토큰은 모든 곡에 "Drake - NOKIA"를 돌려줘서 쓰지 않습니다).
   - 대조(`Choose`/`choose`): 제목이 같아야 합니다(괄호 속 설명 "(feat. …)"·"(시드노벨 - …)"은 무시하고, 리믹스·편곡은 곡도 그런 경우만). 아티스트(또는 제목·앨범이 아닌 Pear 태그)가 맞으면 길이 차이가 `artistTolerance`(기본 15초) 이내, 아티스트가 다르면 제목이 정확히 같고 3초 이내일 때만 받습니다. 제목만 맞는 결과는 LRCLIB 쪽에서도 제목 대조를 허용하고(`titleOnly`), 복제 수 규칙이 1이며, 허용 오차가 3초 이하일 때만 받습니다. 그래서 원곡자가 적힌 커버(`FromSearch`, 복제 수 3)나 원곡자를 모르는 커버(허용 오차 10초)는 아티스트가 맞는 결과만 받습니다. 두 서비스에는 같은 제목의 커버·리믹스가 LRCLIB보다 훨씬 많기 때문입니다.
   - 위의 후보를 2개까지 받아서, 작사·작곡 같은 표기 줄과 Kugou의 첫 줄 "제목 - 아티스트"를 지운 뒤(`CleanLines`) 줄이 3개 이상이고 마지막 줄이 길이 안에 있는(`Fits`) 첫 가사를 씁니다. 출처는 `Kugou`/`NetEase`이고, 커버의 원곡이면 " · 원곡", " · 원곡 검색"이 붙습니다. LRCLIB가 "없음"이라고 답한 곡의 결과만 디스크 캐시에 저장합니다. LRCLIB의 429 때문에 대신 찾은 결과(`LyricsResult.StandIn`, 맥은 `Synced.standIn`)는 이번 실행의 메모리에만 두고, 다음 실행에서는 LRCLIB에 다시 묻습니다(사용자 방침). 곡이 재생되는 동안에도 아래의 곡 단위 재시도로 LRCLIB에 계속 다시 묻습니다. LRCLIB에 싱크 가사가 있으면 바꾸고, "없음"이면 같은 가사를 최종 결과로 디스크에 저장하며 화면은 다시 배치하지 않습니다. 계속 실패하면 대신 찾은 가사를 그대로 둡니다.
   - LRCLIB가 "없음"이라고 해서 저장한 Kugou·NetEase 가사도, 그사이 LRCLIB에 올라왔을 수 있으므로 다시 재생할 때 LRCLIB에 다시 묻습니다(사용자 방침). 저장된 가사를 먼저 표시하고 바로 묻습니다. 같은 실행 안에서는 마지막으로 물은 지 24시간이 지나야 다시 묻습니다(LRCLIB 서버가 답을 24시간 캐시하므로 더 자주 물어도 답이 같습니다). 판단은 `ShouldRecheck`/`shouldRecheck`, 다시 묻는 것은 `Recheck`/`recheck`입니다. 이때는 캐시를 건너뛰고 YouTube Music 가사 단계와 Kugou·NetEase를 빼고(Windows `AsyncLocal` `lrclibOnly`, 맥 `@TaskLocal` `LrclibRecheck.only`) 같은 순서로 찾으므로, 일반 곡은 LRCLIB 요청만 나갑니다(커버는 원곡을 찾기 위한 YouTube 요청도 나가지만 실행 중에는 메모됩니다). LRCLIB가 실패하면 null(`nil`)을 돌려주고, 표시한 가사는 그대로 둔 채 곡 단위 재시도로 다시 묻습니다. 미리 받기에서는 다시 묻지 않고, 곡이 시작될 때 묻습니다.
   - LRCLIB가 바쁘거나(502/503/504) 연결되지 않는 등 다른 이유로 실패하면 Kugou·NetEase에 묻지 않고 LRCLIB에 다시 묻습니다(사용자 방침, 2026-10-20: 대체 서비스는 LRCLIB에 없을 때와 429일 때만).
   - 서비스마다 3번 연달아 실패하면 10분 동안 묻지 않고, "가사 다시 찾기"가 이 대기를 풉니다. 한 서비스라도 묻지 못했는데 가사도 없으면 그 "없음"을 캐시하지 않습니다(`LyricsResult.Unsure`, 맥은 `findSynced`의 `unsure`). 같은 실행 안에서 같은 제목·아티스트·길이는 다시 묻지 않습니다(메모, 200개).
6. LRC를 읽을 때(`Lrc.Parse`/`parseLRC`, LRCLIB·Kugou·NetEase 공통) 같은 시각에 줄이 여럿이면 파일에서 먼저 나온 줄 하나만 남깁니다(`Lrc.FirstPerTime`/`firstPerTime`, 사용자 방침). LRCLIB에는 줄마다 같은 시각으로 로마자 발음이나 번역을 붙인 항목이 있어서(YOASOBI 「アイドル」 215초: "無敵の笑顔で荒らすメディア" 아래에 "Muteki no egao de arasu media"), 두 줄이 다 보이고 강조는 둘째 줄에 갔습니다. 디스크 캐시에서 불러올 때도 같은 처리를 하므로, 1.9.2까지 저장된 항목 때문에 형식 버전을 올리지 않았습니다.
7. `Failed`(서버 오류) 결과는 캐시하지 않습니다. YTM 요청이 오류였고 가사도 찾지 못한 경우에도 캐시하지 않습니다. 다음 곡을 미리 받다가 찾지 못한 결과도 캐시하지 않습니다(곡이 시작되면 Pear가 준 전체 정보로 다시 찾기 위해서입니다).

재시도와 미리 받기 (`TrayApp`):
- LRCLIB 요청 규칙은 [API 문서](https://lrclib.net/docs)(2026-10-20 확인)를 따릅니다. 문서의 내용: 이름을 밝힌 클라이언트(`User-Agent`)는 IP당 1분에 약 90번, 요청은 하나씩 보내고 사이에 200–500ms를 둠, 429와 503에는 `Retry-After`(503은 보통 1초)에 최대 30%의 무작위 시간을 더해 기다린 뒤 다시 보냄(무시하면 일시 차단될 수 있음). 그래서 모든 LRCLIB 요청은 `WaitTurn`/`waitTurn`을 거칩니다: 시작 간격 0.3초, 최근 1분에 60번까지, 바쁨 응답(429/502/503/504)을 받으면 `Retry-After`(없으면 1초)×(1+0–0.3) 동안 모든 요청을 멈춥니다(`nextStart`). 현재 곡 조회와 미리 받기가 이 한도를 함께 씁니다.
- 502/503/504를 받은 요청은 그 대기 뒤에 다시 보내며 4번(`Attempts`/`attempts`)까지 시도합니다. 그래도 바쁘면 `LrclibBusyException`(맥은 domain "LRCLIB" 오류)으로 조회를 끝내고, 곡 단위 재시도가 곧바로 다시 찾습니다(이때 Kugou·NetEase에는 묻지 않습니다). 429는 다시 보내지 않고 바로 조회를 끝내서 Kugou·NetEase가 대신하게 합니다. `Retry-After`가 30초를 넘으면 기다리지 않고 바로 끝내지만, 그 시간 동안 다른 요청도 보내지 않습니다.
- 곡 단위 재시도(`TrayApp.LookUp`, 맥은 `PearClient.lookUp`): 결과가 `Failed`이거나 대신 찾은 가사이면, 곡이 재생되는 동안 최대 10분(`lookupRetryFor`, 일시정지 대비) 계속 다시 찾습니다. 다음 시도까지의 대기(`RetryWait`/`retryWait`)는 직전 10초 안에 바쁨 응답이 있었으면 1초(요청이 `Retry-After`도 기다리므로 사실상 LRCLIB가 허락하는 대로 바로 묻습니다), 아니면(연결 끊김, 시간 초과) 15초입니다. 대신 찾은 가사를 보여 주는 동안에는 LRCLIB에만 다시 묻습니다(`Recheck`).
- 트레이의 "가사 다시 찾기"는 캐시를 지우고(`Forget`) 서킷 브레이커를 해제한(`ResetPause`) 뒤 다시 찾습니다. 이 기능의 단축키는 사용자의 요청에 따라 일부러 만들지 않았습니다.
- 현재 곡의 가사 검색이 끝나고 10초가 지나면 `queue/next`로 다음 곡 정보를 받아 `Prefetch`를 실행합니다. 미리 받은 결과는 가사를 찾은 경우에만 보관합니다.
- **디스크 캐시** (`src/LyricsDiskCache.cs`, `macos/Sources/LyricsDiskCache.swift`, 같은 JSON 형식): LRCLIB·Kugou·NetEase에서 찾은 결과(출처가 `LRCLIB`, `Kugou`, `NetEase`로 시작하는 싱크 가사와 연주곡, 단 LRCLIB 실패를 대신한 Kugou·NetEase 결과는 제외)만 재생 중인 영상의 videoId로 저장합니다. 위치는 Windows `%LocalAppData%\PearNowPlaying\lyrics-cache`, macOS `~/Library/Caches/PearNowPlaying-macOS/lyrics`입니다. 못 찾은 결과와 실패는 저장하지 않고, YouTube Music 결과도 저장하지 않습니다(빠르고 잘 막히지 않기 때문입니다). 90일이 지나면 버리고, 3,000개를 넘으면 오래된 것부터 지웁니다. 항목에는 형식 버전(`version`)이 있으며, 지금 형식(6)보다 오래된 항목은 버립니다. 1.6–1.7.0(형식 1)은 커버곡에 동명이곡 가사를 저장했을 수 있어서 1.7.1에서 2로 올렸고, 1.7.1–1.7.2(형식 2)는 리믹스에 다른 버전의 "연주곡" 표시를 저장했을 수 있어서 1.7.3에서 3으로 올렸고, 1.7.3–1.7.4(형식 3)는 커버곡에 부른 사람의 자작곡 가사를 저장했을 수 있어서 1.7.5에서 4로 올렸고, 1.7.5–1.8.4(형식 4)는 등록된 길이보다 가사가 긴 항목을 저장했을 수 있어서 1.8.5에서 5로 올렸고, 1.8.5–1.8.6(형식 5)은 다른 곡 가사가 이 제목으로 여러 번 올라간 항목을 저장했을 수 있어서 1.8.7에서 6으로 올렸습니다. 판정 규칙이 바뀌어 잘못 저장된 결과가 생길 수 있을 때는 이 버전을 올립니다. videoId는 11자 형식을 확인한 뒤에만 파일 이름으로 씁니다. "가사 다시 찾기"(`Forget`)는 디스크 항목도 지웁니다.
- 나중에 이 앱에 서버가 생기면, 디스크 캐시를 서버 쪽 저장소로 넓혀서 사용자들이 찾은 가사를 공유하는 방안을 검토할 수 있습니다(사용자가 언급한 향후 아이디어이며 아직 계획은 없습니다).
- 미리 받기가 서버 오류(LRCLIB 바쁨 등)로 실패하면, 현재 곡이 재생되는 동안 30초 뒤와 90초 뒤에 다시 시도합니다(대기는 10초 → 30초 → 90초). 곡이 시작된 뒤에 찾으면 늦기 때문입니다. 곡을 넘기면 취소됩니다.
- 커버곡일 수 있는 영상은 설명란 요청을 1단계(YouTube Music 조회)와 동시에 시작합니다. 커버 영상 자체에는 YouTube Music 가사가 거의 없어서, 설명란은 대부분 필요하기 때문입니다.

## YouTube Music 관련 세부 사항 (로그인하지 않은 익명 요청)

- **곡 정보**: `music.youtube.com/youtubei/v1/next`에 WEB_REMIX 클라이언트로 요청합니다.
  - clientVersion은 `"1." + (UTC 기준 2일 전 날짜, yyyyMMdd) + ".01.00"`입니다.
  - 가사 탭의 browseId(`MUSIC_PAGE_TYPE_TRACK_LYRICS`)는 응답을 재귀적으로 탐색해서 찾습니다.
  - `playlistPanelVideoRenderer`에서 제목, 아티스트, 아티스트 ID, 길이, `musicVideoType`을 읽습니다.
- **가사 본문**: 프록시 `ytmbrowseproxy.zvz.be/browse`(Pear 가사 플러그인이 사용하는 것과 같은 중계 서버이며, 설정 항목은 `ytmLyricsProxy`입니다)에 client 26 / 7.01.05로 요청합니다.
  - 이 프록시는 b-ytmbrowseproxy로 리다이렉트하는데, POST 요청을 유지하기 위해 리다이렉트를 직접 따라갑니다.
  - `music.youtube.com`에 직접 browse 요청을 보내면 항상 "Lyrics not available at this time." 응답이 와서, 그 경로는 제거했습니다.
- **어떤 곡에서 싱크 가사를 받을 수 있는지**: 실제로 측정해 보면 공식 음원(ATV)에서만 받을 수 있고, 그것도 대략 4곡 중 3곡 정도입니다.
  - MV, 커버, 일반 업로드 영상은 "not available" 응답을 받거나, 시간 정보가 없는 일반 가사(timedLyricsData에 cueRange가 없음)만 받습니다.
  - 앱에 "출처: Musixmatch"로 표시되더라도 일반 가사일 수 있습니다.
- **서킷 브레이커**: 프록시 요청이 연속으로 3번 실패하면 10분 동안 YTM을 건너뜁니다.
- **공식 음원 찾기** (`FindAudioTrack`):
  - 아티스트 페이지를 hl=ja로 받아서 원래의 일본어 제목을 얻은 뒤, 싱글과 앨범(MPREb_) 중 제목이 맞는 것을 고르고, 그 앨범 페이지의 트랙 중 제목이 같고 길이 차이가 ±5초 이내인 트랙을 고릅니다.
  - 아티스트 페이지에 최근 발매작만 보이면 "모두 보기"(`MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY`) 페이지도 받아서 확인합니다.
  - 곡 이름은 `CoverLyrics.TitleNames`로 여러 개를 추출하며, 그중 하나라도 맞으면 됩니다. 예를 들어 일본어/영어로 나뉜 제목의 각 부분("サイエンス - Science"), 괄호 안의 영어 제목, 아티스트 부분을 뺀 나머지, 커버 제목에 쓰인 이름을 사용합니다.
  - 한계: 곡 이름으로 된 싱글이 없고, 이름이 다른 정규 앨범에만 수록되어 있으면 찾지 못합니다.
- **익명으로 YTM을 검색하면 곡이 결과에 나오지 않기 때문에**(한국 기준) 검색으로 곡을 대조하는 기능은 없습니다. 제목만으로 추정한 원곡은 LRCLIB에서 찾습니다.
- **설명란**: `www.youtube.com/youtubei/v1/player`(WEB)의 `videoDetails.shortDescription`을 사용하고, 이 요청이 실패하면 WEB `next`의 `attributedDescription`과 링크된 videoId를 사용합니다.
- 세션 동안 결과를 기억(메모이즈)하는 대상: Lookup, FindAudioTrack, Description, 아티스트 페이지, 전체 디스코그래피.

## 커버곡 처리 규칙 (`CoverLyrics`)

- `MayBeCover`: 미디어 타입이 비어 있거나 UGC/OTHER_VIDEO일 때, 제목에 cover·歌ってみた 같은 단어가 있을 때, 제목에 업로더가 아닌 아티스트의 이름이 있을 때 커버곡일 수 있다고 판단합니다. 큐에서 가져온 곡(UNKNOWN)은 미디어 타입으로는 판단하지 않고 제목으로만 판단합니다.
- `OriginalCandidates`: 설명란의 링크 중 "原曲·本家·original·원곡"이 적힌 줄의 링크를 먼저 확인합니다. 링크 줄과 그 윗줄을 보고, 빈 줄이나 다른 링크가 끼지 않은 같은 묶음이면 두 줄 위까지 봅니다("■ご本家様：…" / "プロポーズ / 可不" / 링크). 제목 뒤의 `【オリジナル曲】`, `【オリジナル】` 같은 태그는 부른 사람의 자작곡이라는 뜻이므로 원곡 표시로 보지 않습니다(莉犬의 プロポーズ 커버에서 홍보 목록의 자작곡 `Since 1998.`이 원곡으로 잡혔습니다). Mix, Off vocal, illust 같은 단어가 있는 줄의 링크는 뒤로 미룹니다. 후보는 최대 6개이며, 앞의 후보가 쓸 수 없을 때만 다음 후보를 조회합니다(후보 하나에 YouTube Music 요청 1개).
- 원곡이라고 적혀 있지 않은 링크는 `TitleMatchesCover`를 통과해야 사용합니다. 이 검사는 홍보 링크(같은 가수의 다른 커버 등)를 걸러내기 위한 것입니다.
- 원곡 후보(원곡 표시가 있거나 제목이 맞는 링크)를 찾았는데 길이만 맞지 않아서 버린 경우에는 제목만으로 추정하는 `FromSearch`를 하지 않습니다. 제목으로만 찾으면 타이밍이 어긋난 원곡이나 같은 이름의 다른 곡밖에 나오지 않기 때문입니다(실제 사례: VoiSona 雨衣가 커버한 JUNKY의 「メランコリック」에 ナノ의 동명곡 가사가 붙음). 대신 제목이나 설명란에 원곡 아티스트가 적혀 있으면 그 아티스트로만 찾습니다(`FromSearch(byArtist: true)`: 제목만 같은 결과는 받지 않고, 같은 아티스트의 결과도 길이가 커버와 10초 안이어야 함). 원곡 링크가 인트로가 붙은 MV라 길기만 한 경우를 위한 것입니다(실제 사례: 코가네 랑의 호랑풍류가 커버, 링크된 MV 269초, 나래의 음원 251초, 커버 253초). 아티스트가 적혀 있지 않으면 가사 없음으로 끝냅니다.
- 커버일 수 있는 곡(`MayBeCover`)의 마지막 LRCLIB 검색은 아티스트가 맞는 결과만 받습니다(`titleOnly: false`). 업로더는 원곡 아티스트가 아니므로 제목만 같은 결과는 추측일 뿐입니다. 일반 곡의 제목 대조(Mikito-P/みきとP)는 그대로입니다.
- 길이 차이가 10초를 넘거나 `LooksArranged`(remix, arrange, acoustic, 弾き語り, short ver, medley 등)에 해당하면 가사 타이밍이 어긋나므로 사용하지 않습니다.
- 설명란의 원곡·작곡 줄(`DescOriginal`, `DescComposer`)은 앞에 붙은 기호나 이모지("🐯Original:", "■ご本家様：")를 건너뛰고 읽습니다. "Original: 아티스트 - 곡명"처럼 곡명이 함께 적혀 있으면 곡명 쪽을 빼고 아티스트만 씁니다(`ArtistBesideTitle`). "ご本家様 → (링크)"처럼 이름이 없으면 아티스트로 쓰지 않습니다.
- `GuessOriginal`의 제목 해석 규칙:
  - 「」『』 같은 따옴표 안의 이름을 사용하고, 【태그】와 "covered by …" 같은 꼬리 부분을 제거한 뒤, `/ ／ ｜ |`와 " - "를 기준으로 나눕니다.
  - 첫 부분이 업로더(아티스트)의 이름이면 그다음 부분을 곡명으로 봅니다.
  - 설명란의 `原曲：`, `作詞・作曲：`, `Music:` 줄에서 원곡자를 읽습니다.
- `DisplayTitle`(앨범 곡 제목): Pear의 `title`은 YouTube Music 앱 언어로 번역된 제목입니다(`videoDetails.title`, 예: `Only Words`). YouTube Music `next`의 재생목록 항목 제목은 번역이 있으면 "원제 - 번역 (feat. …)"으로 옵니다. 미디어 타입이 AUDIO이고, 재생목록 제목이 정확히 두 부분이며, 뒷부분이 Pear 제목과 같을 때만 카드에 "원제 - 번역"을 보여줍니다. 두 부분이 기호만 다르면(`Xaleid◆scopiX - Xaleid_scopiX`) 같은 이름을 다르게 적은 것이므로 원제만 보여줍니다. 가사 검색과 캐시 키에는 Pear 제목을 그대로 씁니다(`SongInfo.WithTitle`은 카드용 복사본). 재생목록 제목은 가사 검색이 받은 `Lookup` 결과를 재사용하고(`Known`), 가사가 캐시에서 나왔거나 YouTube Music 가사 중계 서버가 서킷 브레이커로 쉬는 중일 때만 제목용 `Lookup(withLyrics: false)`을 한 번 보냅니다. 제목 조회는 중계 서버가 아니라 `music.youtube.com`에 직접 보내므로 서킷 브레이커와 상관없습니다(예전에는 중계 서버가 쉬는 동안 9Lana의 「プロポーズ - propose」가 `propose`로만 나왔습니다). Pear의 `alternativeTitle`(`microformat.linkAlternates`)은 원제일 때도 있고 다른 언어 번역일 때도 있어서 앨범 곡 제목에는 쓰지 않습니다.
- 영상 곡 제목 설정(Windows `videoTitle=true|false`, macOS `videoTitle: "song"|"video"`): 앨범 곡(AUDIO)이 아닌 영상에서 "영상 제목"을 고르면 카드에 `alternativeTitle`(영상에 붙은 제목)을 보여줍니다. Pear의 Discord 플러그인이 `alternativeTitle ?? title`을 쓰기 때문에 사용자 요청으로 고를 수 있게 했습니다. 기본값은 곡 제목(`title`)이며, 커버곡만이 아니라 MV와 일반 업로드에도 적용합니다(커버 판정이 제목에만 기대는 경우가 있어서입니다).
- 아티스트 이름 비교(`SameArtist`)는 대소문자, 전각/반각, 문장부호, 악센트를 무시합니다("fhána"와 "fhana"를 같은 이름으로 봅니다).

로그에서 확인한 해석상의 약점:
- 「」 안에 곡명이 아니라 애니메이션 제목이 들어 있는 경우가 있습니다. 예를 들어 "This Game「ノーゲーム・ノーライフ」OPテーマ"에서는 애니메이션 제목이 곡명으로 잡힙니다.
- "(傘村トータ)"처럼 괄호 안에 들어 있는 작곡가 이름이 곡명에 남습니다.
- 채널 이름이나 "고음질 버전" 같은 문구가 아티스트로 잡히는 경우가 있습니다.

## 지켜야 할 것

- **Google 계정 쿠키나 Pear 로그인 세션은 사용하지 않습니다.** Pear 토큰은 로컬 Pear API 서버 외에는 어디에도 보내지 않습니다. YouTube Music 요청은 모두 익명으로 보냅니다.
- YouTube 오디오를 다운로드하거나 재전송하는 기능, 자막을 수집하는 기능 같은 것은 만들지 않습니다.
- 브라우저에서는 YouTube Music 탭의 주소와 제목만 읽습니다. 다른 탭의 주소나 방문 기록, 쿠키는 읽지 않고, 탭 주소를 로그에 남기지 않습니다(videoId만 남깁니다).
- 새로운 외부 서버와 통신하게 되면 README의 "통신하는 곳" 항목에 추가합니다.
- 외부 요청은 줄이는 방향으로 작업합니다. LRCLIB에 대해서는 위의 요청 규칙(간격, 1분 한도, `Retry-After`)을 지키는 범위에서 다시 묻는 것을 허용합니다(사용자 방침, 2026-10-20). 429를 받지 않는 것이 기준입니다.
- LRCLIB의 503은 사용자별 요청 제한이 아니라 서버 전체의 과부하 신호입니다(서버 소스 `server/src/state.rs`: DB 작업을 동시에 32개까지만 받고, 250ms 안에 자리가 나지 않으면 503). `/api/get`과 `/api/search` 응답은 서버가 24시간 캐시하며, 캐시에 있는 요청은 이 제한을 거치지 않습니다. 따라서 503은 클라이언트에서 없앨 수 없습니다. API 문서는 503에 `Retry-After`를 지켜서 다시 묻도록 안내합니다. `/api/get`은 아티스트 이름이 반드시 있어야 하므로, 원곡자를 모르면 검색만 사용합니다.
- 실패한 결과를 "가사 없음"으로 캐시하지 않습니다. 일시적인 오류가 영구적인 "없음"으로 남으면 안 됩니다.
- Pear 토큰은 메뉴의 **Pear Desktop 연결 요청**(`RetryAuth`/`retryAuth`)을 눌렀을 때와, 받아 둔 토큰이 거절되었을 때(만료)만 요청합니다(사용자 방침, 2026-10-20). 처음 실행할 때 저절로 요청하지 않으므로 브라우저만 쓰는 사용자에게 Pear의 허용 창이 뜨지 않고, 토큰이 없으면 상태는 `NotLinked`/`notLinked`("Pear Desktop 연결 안 됨")입니다. 요청하기 전에 API 서버가 응답하는지(`GET /api/v1/song`, 아무 상태 코드나 됨) 확인하고, 응답이 없으면 안내 카드만 한 번 띄웁니다. Windows는 닫힌 로컬 포트에 연결하면 거절되기까지 약 2초가 걸려서, 예전 방식(0.8초 안에 답이 없으면 허용 창이 떠 있다고 봄)으로는 Pear가 없는 PC에서 "'허용'을 눌러 주십시오" 알림이 몇 초마다 반복되었습니다(2.0.0 사전 릴리스에서 발견).
- Pear 3.12.0에서 일시정지·재생해도 `PLAYER_STATE_CHANGED`가 오지 않고, Pear 자신의 곡 정보도 `isPaused: false`로 남는 것을 확인했습니다(2026-10-20, 사용자는 이전에는 일시정지가 반영되었다고 기억함, Pear 쪽 문제로 추정). Pear는 재생 중에만 1초마다 위치를 보내므로, Pear 곡이 재생 중인데 위치가 2.5초 넘게 오지 않으면 마지막 위치에서 일시정지한 것으로 보고, 그 뒤에 위치가 오면 다시 재생으로 봅니다(`CheckPearSilence`/`checkPearSilence`). Pear가 상태를 직접 보내면 그 상태를 따르고, 그때는 일시정지 중에 오는 위치(탐색)로 재생을 추정하지 않습니다.
- WebSocket(`/api/v1/ws`) 토큰은 `?token=` 쿼리 파라미터와 `Authorization: Bearer` 헤더로 **함께** 보냅니다. Pear 3.11은 연결 요청의 헤더만 확인해서 401로 거절하고, 3.12(#3854 이후)는 쿼리만 확인해서 1008로 연결을 닫습니다. 어느 한쪽만 보내면 다른 버전에서 연결되지 않습니다(1.5.1 맥 버전이 헤더만 보내서 3.12에서 "Pear 연결 실패 (57)"이 반복되었습니다). 모의 서버 테스트(`macos/Tests/mock_pear.py`)는 두 방식을 모두 확인합니다.
- Pear는 곡이 끝날 때 이전 곡의 `POSITION_CHANGED`를 `VIDEO_CHANGED`보다 먼저 보냅니다. 보통은 위치 0이 0.3–0.7초 먼저 오고(2026-10-19, 10-20 실측), 가끔은 그 앞에 엉뚱한 값이 한 번 더 옵니다(2026-10-20: 190 다음에 115, 다음 곡 길이는 114초). 그대로 받으면 이전 곡이 되감긴 것처럼 보여서 가사가 위로 올라갔다가 다음 곡 처음으로 갑니다. 그래서 2초 넘게 뒤로 가는 위치는 한 번 보류하고, 다음 위치가 그 값에서 이어질 때만 반영합니다(`PositionFilter`, 맥 `BackwardJumps`). `VIDEO_CHANGED`·`PLAYER_INFO`·`PLAYER_STATE_CHANGED`는 보류를 풉니다. 그래서 직접 뒤로 되감거나 같은 곡을 반복하면 다음 위치 메시지(1초 뒤)부터 반영됩니다. 1.7.5에서는 곡의 마지막 3초 안에 온 0만, 1.8.7부터 1.9.3까지는 10초 이후에서 0으로 돌아가는 위치만 무시해서 115 같은 값은 걸러지지 않았습니다.
- HttpClient의 타임아웃도 TaskCanceledException을 던집니다. 실제로 취소된 것인지는 `catch … when (ct.IsCancellationRequested)`로 구분합니다. 예전에 이 구분을 하지 않아서 가사 상태가 "찾는 중"에서 멈춘 적이 있습니다.
- 메뉴는 위젯 설정(곡 정보 계속 표시, 영상 곡 제목, 표시, 위치, 크기, 투명도, 끌어서 옮기기)과 가사 설정(가사 표시, 다시 찾기, 타이밍)을 하위 메뉴로 나눕니다. "YouTube Music 가사 먼저 찾기"는 사용자 요청으로 메뉴에서 뺐고, 설정 파일의 `ytmLyrics`로만 바꿉니다. `alwaysShow`의 기본값은 `true`입니다(기존 설정 파일의 값은 그대로 둡니다).
- **위젯은 모니터마다 하나씩** 둘 수 있고 위치도 모니터마다 다릅니다. Windows는 `Config.Widgets`(`WidgetPlace`, config.ini의 `widgetN=위치`, N은 메뉴의 모니터 번호)와 `OverlayGroup`(모니터별 `OverlayWindow`를 하나처럼 다룸)을 씁니다. 맥은 `Settings.widgets`(`WidgetSetting`)와 `OverlayController.widgets`(`WidgetPanels`)입니다. 표시 상태(카드 종류, 숨김 시점, 가사 스크롤)는 모든 위젯이 공유하고, 위치·크기·투명도는 위젯마다 다릅니다.
  - 크기: Windows는 크기가 다른 위젯마다 그림을 따로 그립니다(`lookScales`의 크기마다 `CardFrame`과 `LyricsView`를 하나씩 두고, 같은 크기의 창끼리는 복사본을 나눠 가짐, `PerLook`). 가사 뷰들은 같은 호출을 받으므로 첫 뷰(`MainView`)가 상태 질문에 답합니다. 맥은 같은 그림을 위젯마다 다른 배율(`OverlayCanvas.scale`)로 그립니다. 1.7까지의 설정에는 위젯별 크기가 없어서, 공통 `scale` 값에서 시작합니다(Windows `widgetNScale`, 맥 `widgets[].scale`).
  - 투명도: 글자까지 포함한 위젯 전체의 투명도입니다(Windows `widgetNTransparency`, 맥 `widgets[].transparency`, 0–0.8). Windows는 `OverlayWindow.MaxAlpha`로 `UpdateLayeredWindow`의 알파에 곱하고, 맥은 `OverlayPanel.maxAlpha`를 페이드의 목표 알파로 씁니다. 공통 `opacity`는 예전처럼 카드 배경의 불투명도입니다.
  - 메뉴: **표시**는 위젯을 띄울 모니터를 켜고 끄는 목록이며, 모니터가 하나이면 숨깁니다. 끈 위젯은 지우지 않고 숨김 표시만 해서(Windows `widgetNShow=false`/`WidgetPlace.Hidden`, 맥 `hidden`) 다시 켜면 위치·크기·투명도가 돌아옵니다(1.8.1부터, 1.8.0까지는 지웠음). 켜진 위젯(`OnWidgets`/`onWidgets`)이 최소 하나는 남습니다. **위치**, **크기**, **투명도**는 위젯이 여러 개이면 위젯이 있는 모니터마다 하위 메뉴, 하나이면 선택지를 바로 보여줍니다. 연결이 끊긴 모니터의 위젯은 숨기고(하나도 없으면 첫 위젯을 주 모니터에), 모니터 구성이 바뀌면 다시 만듭니다. 모니터는 연결 순서의 번호로 구분하므로 다시 꽂으면 번호가 바뀔 수 있습니다. 끌어서 놓은 위젯은 자기 모니터 안에 머뭅니다.
- 위젯은 평소 클릭을 통과시켜야 합니다(게임 위에 뜨기 때문입니다). 마우스를 받는 것은 "위젯 끌어서 옮기기" 모드가 켜져 있는 동안뿐이며, 이 모드에서는 곡 카드가 사라지지 않습니다. 놓으면 중심이 있는 모니터와 위·아래 절반을 기준으로 `Custom` 위치를 저장합니다.
- 곡이 바뀔 때 가사가 이미 알려져 있으면(이번 실행의 캐시, 미리 받은 결과, 디스크 캐시: `LyricsProvider.Known` / `LyricsFinder.known`) 가사 카드를 닫지 않고 내용만 바꿉니다. 예전에는 카드를 먼저 닫았다가 다시 열어서, 아래쪽 배치에서 곡 카드가 내려갔다가 올라가는 문제가 있었습니다. 모르는 곡일 때만 카드를 닫고 찾습니다. 이렇게 내용을 바꿀 때는 이전 곡에서 강조되어 있던 줄과 그 앞 줄을 새 곡의 첫 줄 위에 남겨 두고, 그 줄에서 새 곡의 줄로 이어서 스크롤합니다(`LyricsView.SetLines`의 `carryOver`, 맥은 `NativeLyricsLayout.setLines`의 `carryFrom`). 같은 곡의 가사가 다시 바뀌거나, 크기·너비가 바뀌거나, 가사 카드가 닫혀 있던 경우에는 처음부터 배치합니다. 다음 곡 가사를 미리 받으면 지금 곡의 마지막 줄 아래에 다음 곡의 줄을 붙여 둡니다(`SetNext`/`setNext`, 미리 받은 결과를 소모하지 않는 `LyricsProvider.Ahead`/`LyricsFinder.ahead`로 읽음). 그래서 곡이 끝나 갈 때 다음 곡의 첫 줄이 이미 보입니다. 곡이 바뀔 때 이전 곡의 남은 줄이 3줄 이하이면 남은 줄을 모두 남겨서, 미리 보이던 다음 곡 줄이 같은 자리에 그대로 있게 합니다. 강조 줄은 지금 곡의 줄을 넘어가지 않습니다. 이전 곡이 "♪"(빈 줄)로 끝나고 다음 곡이 "♪"로 시작하면 두 줄을 하나로 합쳐서, 이전 곡의 마지막 "♪"를 다음 곡의 첫 줄로 씁니다(`mergedGap`).
- 정보 카드("가사 다시 찾기" 결과 등)가 표시되는 동안에는 곡 카드를 다시 그리지 않습니다. 계속 표시 모드에서는 정보 카드가 3.5초 뒤에 곡 카드로 돌아갑니다. 예전에는 이 두 동작이 서로 꼬여서 곡 카드가 사라지는 버그가 있었습니다. macOS 버전도 같은 방식으로 동작합니다.
