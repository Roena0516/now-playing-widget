# CLAUDE.md

Pear Now Playing: Pear Desktop(YouTube Music 데스크톱 클라이언트)에서 재생 중인 곡을 화면 위에 띄우는 Windows 오버레이 위젯. 곡 카드와 싱크 가사를 보여줌. 원래 Euro Truck Simulator 2용 "ETS2 Now Playing"으로 시작했고, 게임과 상관없이 쓸 수 있어서 이름에서 ETS를 뺐음.

- 저장소: `Roena0516/pear-now-playing`
- 사용자 문서: `README.md` (한국어, 해요체)
- 버전: `src/Program.cs`의 AssemblyVersion (현재 1.5.0.0), 맥은 `macos/Sources/Models.swift`의 `appVersion`과 `macos/build.sh`의 Info.plist
- macOS 버전: `macos/` (Swift/AppKit, pdh0128의 PR #1에서 시작). 가사 찾는 순서는 Windows와 똑같이 맞춰 둠. 가사 쪽을 고치면 양쪽을 같이 고침 (`src/Lyrics.cs` ↔ `LyricsFinder.swift`·`LyricsProvider.swift`, `YtmLyrics.cs` ↔ `YTMusicProvider.swift`, `CoverLyrics.cs` ↔ `CoverLyrics.swift`)

## 작업 방식

- 사용자(로에나)는 반말 한국어(임/함체)로 짧고 직접적인 답을 선호함.
- 커밋, 푸시, 릴리스 업로드는 사용자가 직접 함. 릴리스 zip에는 `PearNowPlaying.exe`, `README.md`, `PretendardJP-OFL.txt`가 `PearNowPlaying/` 폴더째 들어감.
- 맥 릴리스는 `./macos/build.sh --universal`(arm64+x86_64) 후 `ditto -c -k --norsrc --keepParent 'macos/build/Pear Now Playing.app' PearNowPlaying-macOS.zip`. ad-hoc 서명이고 공증은 안 함.
- 커밋 메시지는 한국어로 짧게 씀 (예: "트레이 가사 다시 찾기에 결과 표시").
- 릴리스 본문은 합니다체로 씀.
- 루트의 `PearNowPlaying.exe`, `_capture/`, `*.zip`은 커밋하지 않음 (`.gitignore`).
- 실행 로그는 `%AppData%\PearNowPlaying\error.log`, 설정은 `%AppData%\PearNowPlaying\config.ini`에 있음. 가사가 안 뜬다는 제보는 로그부터 봄. 가사 검색 단계마다 INFO 줄이 남음.

## 빌드

macOS: `./macos/build.sh` (Xcode Command Line Tools). 테스트: 앱 실행 파일에 `--self-test`, `--lyrics-tests`, `--ytmusic-tests`, 그리고 `python3 macos/Tests/mock_pear.py`. `--lyrics-tests`의 커버곡 케이스(`CoverTests.swift`)는 C# 결과를 그대로 기대값으로 넣은 것이라, `CoverLyrics.cs`를 바꾸면 같이 갱신함. GitHub Actions `macOS` 워크플로가 같은 테스트를 돌림.

Windows:

- C# 7.3, .NET Framework 4.8, WinForms. 외부 패키지 없음 (JSON은 `System.Web.Extensions`의 JavaScriptSerializer).
- Windows: `dotnet build -c Release` (`PearNowPlaying.csproj`, SDK 스타일 net48).
- Linux: `sh build.sh` → `bin/PearNowPlaying.exe`. dotnet SDK의 Roslyn `csc.dll`에 Mono 참조 어셈블리(`/usr/lib/mono/4.8-api`)를 붙여 빌드함.
- 폰트(Pretendard JP Regular/Medium)와 글리프 커버리지 파일은 EmbeddedResource이고, LogicalName은 파일 이름 그대로임. csproj와 build.sh 양쪽을 같이 맞춰야 함.
- C# 7.3 제약: `?.`는 쓸 수 있지만 switch 식, `using` 선언, nullable 참조 형식, 범위 연산자는 못 씀.
- 저장소에 테스트 프로젝트는 없음. 지금까지는 저장소 밖에서 `src/*.cs`(Program.cs 제외)를 테스트 파일과 함께 컴파일하고, LRCLIB·YouTube Music·Pear를 흉내 내는 로컬 mock 서버(aiohttp)를 띄워 Mono로 돌렸음. 클래스 대부분이 `internal`이라 exe를 참조하는 방식으로는 테스트를 못 함.

## 구조

| 파일 | 내용 |
|---|---|
| `src/Program.cs` | 진입점, 단일 인스턴스, 버전 |
| `src/PearClient.cs` | Pear API 서버 플러그인과 통신: `POST /auth/{id}`로 토큰 발급(처음 한 번 Pear가 허용 창을 띄움), WebSocket `/api/v1/ws`, `POST /api/v1/next`·`previous`·`toggle-play`, `GET /api/v1/queue/next`(다음 곡). `SongInfo.MediaType`: AUDIO / ORIGINAL_MUSIC_VIDEO / USER_GENERATED_CONTENT / PODCAST_EPISODE / OTHER_VIDEO, 큐에서 온 곡은 UNKNOWN |
| `src/OverlayWindow.cs` | 클릭이 통과하는 항상 위 레이어드 창(`UpdateLayeredWindow`), 페이드·이동 애니메이션 |
| `src/CardRenderer.cs` | 곡 카드 그리기, 긴 제목 마퀴 |
| `src/LyricsView.cs` | 가사 목록 스크롤, 줄 전환 애니메이션 |
| `src/Lyrics.cs` | `LyricsProvider`: 가사 찾는 순서 전체, 캐시, 미리 받기, LRCLIB 검색, LRC 파서 |
| `src/YtmLyrics.cs` | YouTube Music: 곡 정보, 가사(프록시 경유), 공식 음원 찾기, 영상 설명란 |
| `src/CoverLyrics.cs` | 커버곡 판별, 설명란 원곡 링크 고르기, 제목에서 곡명·원곡자 추출, 편곡·리믹스 거르기 (순수 함수 위주) |
| `src/TrayApp.cs` | 트레이 메뉴, 곡 카드·정보 카드 표시 타이밍, 가사 재시도 루프, 다음 곡 미리 받기 |
| `src/Config.cs` | config.ini 읽기/쓰기, 예전 ETS2NowPlaying 설정 이전(`MigrateOldConfig`), 토큰 저장 |
| `src/Hotkeys.cs`, `src/Native.cs`, `src/Theme.cs` | 전역 단축키, Win32 P/Invoke, 색 토큰과 폰트 로딩 |

## 가사 찾는 순서 (`LyricsProvider.Find`)

1. 캐시 → 미리 받아둔 결과(videoId 기준)
2. **YouTube Music** (`ytmLyrics=true`이고 서킷 브레이커가 쉬는 중이 아닐 때)
   - 그 영상 자체의 싱크 가사
   - 없으면 같은 아티스트 앨범에서 공식 음원(ATV)을 찾아 그 가사 (출처 "YouTube Music · 공식 음원")
3. **커버곡이면 원곡 가사** (`CoverLyrics.MayBeCover`)
   - `FromOriginal`: 설명란 링크 중 원곡 후보 → 원곡의 YTM 가사 → 원곡의 공식 음원 가사 → 원곡 제목으로 LRCLIB
   - 링크가 없으면 `FromSearch`: 제목·설명란에서 곡명과 원곡자를 추정(`GuessOriginal`)해 LRCLIB 검색
4. **LRCLIB** (`FindLrclib`): `/api/get`(정확한 제목·아티스트·앨범·길이, 다른 제목으로 최대 3번) → `/api/search` → `q=` 검색 최대 3번 → 제목이 같고 길이가 맞는 결과 고르기(기본 ±3초, 커버는 ±10초)
5. `Failed`(서버 오류)인 결과는 캐시하지 않음. YTM이 오류였고 가사도 못 찾았으면 역시 캐시하지 않음.

재시도와 미리 받기 (`TrayApp`):
- LRCLIB가 바쁨(429/502/503/504 → `LrclibBusyException`)이면 요청마다 2초 뒤 한 번 더 시도함. 그래도 실패하면 곡 단위로 15초, 45초 뒤에 다시 찾음.
- 트레이의 "가사 다시 찾기"는 캐시를 지우고(`Forget`) 서킷 브레이커를 풀고(`ResetPause`) 다시 찾음. 단축키는 일부러 안 만들었음 (사용자 요청).
- 현재 곡의 가사 검색이 끝나고 10초 뒤 `queue/next`로 다음 곡을 받아 `Prefetch`함. 찾은 결과만 보관함.

## YouTube Music 쪽 세부 사항 (로그인 없이 익명 요청)

- **곡 정보**: `music.youtube.com/youtubei/v1/next`에 WEB_REMIX 클라이언트로 요청함.
  - clientVersion은 `"1." + (UTC 기준 2일 전 yyyyMMdd) + ".01.00"`.
  - 가사 탭의 browseId(`MUSIC_PAGE_TYPE_TRACK_LYRICS`)를 재귀로 찾음.
  - `playlistPanelVideoRenderer`에서 제목, 아티스트, 아티스트 ID, 길이, `musicVideoType`을 읽음.
- **가사 본문**: 프록시 `ytmbrowseproxy.zvz.be/browse`(Pear 가사 플러그인과 같은 중계 서버, 설정 `ytmLyricsProxy`)에 client 26 / 7.01.05로 요청함.
  - b-ytmbrowseproxy로 리다이렉트되는데, POST를 유지하려고 직접 따라감.
  - `music.youtube.com`에 직접 browse하면 항상 "Lyrics not available at this time."이 와서 그 경로는 지웠음.
- **어떤 곡에 싱크 가사가 오나**: 실측으로는 공식 음원(ATV)에만 오고, 그것도 대략 4곡 중 3곡꼴임.
  - MV, 커버, 일반 업로드는 "not available"이거나 시간 없는 일반 가사(timedLyricsData에 cueRange 없음)만 옴.
  - 앱에 "출처: Musixmatch"로 나와도 일반 가사일 수 있음.
- **서킷 브레이커**: 프록시가 연속 3번 실패하면 10분 동안 YTM을 건너뜀.
- **공식 음원 찾기** (`FindAudioTrack`):
  - 아티스트 페이지를 hl=ja로 받아 원래 일본어 제목을 얻음 → 싱글·앨범(MPREb_) 중 제목이 맞는 것 → 앨범 페이지의 트랙 중 제목이 같고 길이가 ±5초 안인 것.
  - 아티스트 페이지에 최근 발매만 보이면 "모두 보기"(`MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY`)도 받아 봄.
  - 곡 이름은 `CoverLyrics.TitleNames`로 여러 개를 뽑아 하나라도 맞으면 됨. 예: 일본어/영어 반쪽("サイエンス - Science"), 괄호 안 영어 제목, 아티스트 부분을 뺀 나머지, 커버 제목에 쓰인 이름.
  - 한계: 곡 이름의 싱글이 없고 이름이 다른 정규 앨범에만 있으면 못 찾음.
- **익명 YTM 검색은 곡을 돌려주지 않아서**(KR) 검색 기반 매칭은 없음. 제목만으로 추정한 원곡은 LRCLIB로 찾음.
- **설명란**: `www.youtube.com/youtubei/v1/player`(WEB)의 `videoDetails.shortDescription`을 쓰고, 안 되면 WEB `next`의 `attributedDescription`과 링크된 videoId를 씀.
- 세션 동안 메모이즈하는 것: Lookup, FindAudioTrack, Description, 아티스트 페이지, 전체 디스코그래피.

## 커버곡 처리 규칙 (`CoverLyrics`)

- `MayBeCover`: 미디어 타입이 UGC/OTHER/UNKNOWN이거나, 제목에 cover·歌ってみた 같은 말이 있거나, 제목에 올린 사람이 아닌 아티스트 이름이 있을 때.
- `OriginalCandidates`: 설명란 링크 중 원곡·本家·original·원곡이 적힌 줄의 링크를 먼저 봄. Mix, Off vocal, illust 같은 줄의 링크는 뒤로 미룸. 최대 3개.
- 원곡이라고 적히지 않은 링크는 `TitleMatchesCover`를 통과해야 씀. 홍보 링크(같은 가수의 다른 커버 등)를 걸러내기 위함.
- 길이 차이가 10초를 넘거나 `LooksArranged`(remix, arrange, acoustic, 弾き語り, short ver, medley …)면 싱크가 어긋나므로 쓰지 않음.
- `GuessOriginal`의 제목 파싱 규칙:
  - 「」『』 같은 따옴표 안의 이름, 【태그】 제거, "covered by …" 꼬리 제거, `/ ／ ｜ |`와 " - "로 나눔.
  - 첫 부분이 업로더(아티스트) 이름이면 그 다음 부분을 곡명으로 봄.
  - 설명란의 `原曲：`, `作詞・作曲：`, `Music:` 줄에서 원곡자를 읽음.
- 아티스트 이름 비교(`SameArtist`)는 대소문자, 전각/반각, 문장부호, 악센트를 무시함 ("fhána" = "fhana").

알려진 파싱 약점(로그에서 본 것):
- 「」가 곡명이 아니라 애니 이름일 때가 있음. 예: "This Game「ノーゲーム・ノーライフ」OPテーマ"가 애니 이름으로 잡힘.
- "(傘村トータ)"처럼 괄호에 든 작곡가가 곡명에 남음.
- 채널 이름이나 "고음질 버전" 같은 말이 아티스트로 잡히는 경우가 있음.

## 지켜야 할 것

- **Google 계정 쿠키나 Pear 로그인 세션은 쓰지 않음.** Pear 토큰은 로컬 Pear API 서버 말고는 어디에도 보내지 않음. YouTube Music 요청은 전부 익명임.
- YouTube 오디오 다운로드·재전송, 자막 스크래핑 같은 기능은 만들지 않음.
- 새 외부 서버와 통신하게 되면 README의 "통신하는 곳" 표에 추가함.
- 외부 요청은 줄이는 방향으로 함. LRCLIB는 자주 503을 내므로 요청 수를 늘리는 변경은 신중히 함.
- 실패를 "가사 없음"으로 캐시하지 않음. 일시적인 오류가 영구적인 "없음"이 되면 안 됨.
- HttpClient 타임아웃도 TaskCanceledException을 던짐. 진짜 취소인지는 `catch … when (ct.IsCancellationRequested)`로 구분함. 예전에 이걸 안 해서 상태가 "찾는 중"에서 멈춘 적이 있음.
- 정보 카드("가사 다시 찾기" 결과 등)가 떠 있는 동안에는 곡 카드 다시 그리기를 건너뜀. 계속 표시 모드에서는 3.5초 뒤 곡 카드로 돌아감. 이 둘이 꼬여서 곡 카드가 사라지는 버그가 있었음.
- UI 문자열과 README는 한국어(해요체), 코드 주석과 로그는 영어로 씀.
