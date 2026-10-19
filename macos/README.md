# Pear Now Playing for macOS

이 앱은 Pear Now Playing을 macOS 13 이상에서 실행할 수 있도록 Swift/AppKit으로 옮긴 네이티브 버전입니다. Windows 버전과 같은 Pear Desktop API를 사용하며, 별도의 런타임이나 외부 Swift 패키지가 필요하지 않습니다.

## 빌드 및 실행

빌드하려면 Xcode Command Line Tools와 macOS SDK가 필요합니다. 설치 여부는 `xcrun swift --version`으로 확인할 수 있습니다.

```sh
./macos/build.sh
open 'macos/build/Pear Now Playing.app'
```

기본 빌드는 현재 Mac의 아키텍처(Apple Silicon 또는 Intel)에 맞춰 만들어집니다. `./macos/build.sh --universal`로 빌드하면 두 아키텍처를 모두 담은 앱이 만들어집니다. `--dmg`를 함께 붙이면 설치용 디스크 이미지(`macos/build/PearNowPlaying-macOS-<버전>.dmg`)도 만들어집니다. 이 DMG를 열면 앱 아이콘과 `Applications` 폴더 바로 가기가 화살표 배경 위에 나란히 표시됩니다. DMG 창의 모양은 [`dmgbuild`](https://github.com/dmgbuild/dmgbuild)로 만들며, 처음 `--dmg`로 빌드할 때 `macos/build/dmg-venv`에 설치되므로 그때는 인터넷 연결이 필요합니다. 릴리스에는 `./macos/build.sh --universal --dmg`로 만든 DMG 파일을 올립니다.

앱 아이콘(`macos/Resources/AppIcon.icns`)과 DMG 배경(`macos/Resources/dmg-background.tiff`)은 `xcrun swift macos/Tools/make-art.swift`로 그립니다. 그린 결과 파일은 저장소에 들어 있으므로, 디자인을 바꿀 때만 이 스크립트를 실행하면 됩니다. 빌드 결과는 `macos/build/Pear Now Playing.app`에 생성되고, 원하는 Applications 폴더로 복사해서 사용할 수 있습니다. 앱에는 개발용 ad-hoc 서명만 되어 있으며, Apple의 공증은 받지 않았습니다.

1. Pear Desktop 또는 호환되는 YouTube Music 데스크톱 앱을 실행합니다.
2. **플러그인 → API 서버 [베타]**를 켭니다. 호스트는 `127.0.0.1`, 포트는 `26538`으로 설정하는 것을 권장합니다.
3. 이 앱을 실행한 뒤, Pear에 나타나는 `pear-now-playing-macos` 연결 요청을 **허용**합니다.
4. 음악을 재생하면 곡 카드가 나타납니다. 상태와 설정은 메뉴 막대의 음표 아이콘에서 확인할 수 있습니다. 이 앱은 Dock에 표시되지 않습니다.

API 서버가 꺼져 있다면 메뉴에서 **Pear 연결 권한 다시 요청**을 선택합니다. 이 메뉴를 선택하면 앱은 음악 앱의 `config.json`을 백업한 뒤 API 서버를 켜고, 호스트를 `127.0.0.1`로, 포트를 위젯 설정과 같은 값으로 저장합니다. 또한 로컬 HTTP 연결을 사용하도록 `useHttps`를 끄며, 기존의 인증 정책과 다른 플러그인 설정은 그대로 유지합니다. 이 기능이 지원하는 설정 폴더는 `YouTube Music`, `Pear Desktop`, `pear-desktop`입니다.

설정을 저장한 뒤에는 연결을 다시 시도합니다. 실행 중인 음악 앱에 변경 사항이 바로 반영되지 않으면, 앱이 **음악 앱 다시 시작** 버튼을 보여줍니다. 음악 앱을 다시 시작하면 재생 중인 음악이 잠시 멈춥니다. 쓰기 권한이 없거나 설정 파일에 문제가 있으면 앱이 오류 메시지를 표시합니다. API 서버가 이미 켜져 있는 상태에서도 같은 메뉴로 연결 권한을 다시 요청할 수 있습니다.

음악 앱 없이 화면 표시만 확인하려면, 실행 중인 Pear Now Playing을 메뉴에서 종료한 뒤 아래 명령을 실행합니다.

```sh
open 'macos/build/Pear Now Playing.app' --args --preview
```

미리보기 모드는 실제 음악 앱에 연결하지 않습니다. 일반 모드로 돌아가려면 앱을 종료한 뒤 다시 실행합니다.

## 기능

- 오버레이는 포커스를 가져가지 않으며, 클릭과 키 입력을 아래에 있는 앱으로 그대로 전달합니다. 모든 데스크톱 공간과 전체 화면 공간에 표시됩니다.
- 곡이 바뀌거나 재생 상태가 바뀌면 앨범 아트, 아티스트·앨범, 실시간 진행 바를 표시하고, 긴 제목은 스크롤합니다.
- 가사는 Windows 1.5.0과 같은 순서로 찾습니다: YouTube Music 가사, MV라면 공식 음원의 가사, 커버곡이라면 원곡의 가사, 마지막으로 LRCLIB 순서입니다.
- LRCLIB 검색 순서도 Windows 버전과 같습니다. 대체 제목과 정리한 제목으로 검색하고, 아티스트·태그의 유사도와 재생 길이로 결과를 확인하며, 결과를 캐시하고, 네트워크 오류가 나면 다시 시도합니다.
- Pear 재생목록에 있는 다음 곡의 가사를 미리 찾아 둡니다.
- 현재 가사 줄을 강조하면서 스크롤하고, 가사 타이밍을 보정할 수 있으며, 한국어와 일본어를 Pretendard JP 폰트로 표시합니다.
- 메뉴 막대에서 재생을 제어할 수 있습니다. 설정은 **위젯** 메뉴(곡 정보 계속 표시, 위치, 모니터, 크기, 위젯 끌어서 옮기기)와 **가사** 메뉴(가사 표시, 가사 다시 찾기, 가사 타이밍, 가사 진단 기록 열기)로 나뉘어 있습니다.
- **위젯 끌어서 옮기기**를 켜면 위젯을 마우스로 끌어서 원하는 곳(다른 모니터 포함)에 놓을 수 있고, 다시 누르면 끝납니다. 평소에는 위젯이 클릭을 통과시키기 때문에 이 항목이 켜져 있는 동안에만 끌 수 있습니다. 화면의 아래쪽 절반에 놓으면 가사 카드가 아래에 고정되고, 위쪽 절반에 놓으면 곡 카드가 위에 고정됩니다. 놓은 위치는 **위치 → 직접 옮긴 위치**로 저장됩니다.
- 모니터가 여러 대이면 **위젯 → 모니터**에서 위젯을 표시할 모니터를 고를 수 있습니다.
- 토큰이 만료되면 다시 인증하고, 연결이 끊기면 다시 접속합니다. 토큰 파일의 권한은 `0600`으로 저장합니다.

macOS의 창 관리 정책 때문에, 일부 독점 전체 화면 앱 위에서는 오버레이가 보이지 않을 수 있습니다.

| 단축키 | 기능 |
|---|---|
| `Control + Option + ↑` | 지금 곡 다시 보기 |
| `Control + Option + ↓` | 재생 / 일시정지 |
| `Control + Option + →` | 다음 곡 |
| `Control + Option + ←` | 이전 곡 |
| `Control + Option + P` | 계속 표시 |
| `Control + Option + L` | 가사 표시 |

단축키는 Carbon 전역 단축키 API로 등록하므로 손쉬운 사용(접근성) 권한이 필요하지 않습니다. 다른 앱이 이미 사용 중인 조합은 등록되지 않으며, 그 사실이 Console에 기록됩니다. macOS 버전에서는 단축키 조합을 바꿀 수 없습니다.

## 가사

가사는 Windows 1.5.0(`src/Lyrics.cs`, `src/YtmLyrics.cs`, `src/CoverLyrics.cs`)과 같은 순서로 찾습니다.

1. **YouTube Music**: 재생 중인 영상의 싱크 가사를 Pear의 YTMusic 가사 제공자와 같은 중계 서버(`ytmbrowseproxy.zvz.be`)를 통해 받습니다. 로그인하지 않은 상태로 YouTube Music에 직접 요청하면 가사를 받을 수 없으므로, 직접 요청은 보내지 않습니다.
2. **공식 음원**: 싱크 가사는 대부분 공식 음원에만 제공됩니다. 그래서 MV를 재생할 때는 YouTube Music의 아티스트 페이지(필요하면 전체 디스코그래피)에서 같은 제목의 싱글이나 앨범을 찾고, 길이 차이가 5초 이내인 공식 음원의 가사를 대신 사용합니다.
3. **커버곡**: 개인이 업로드한 영상이거나 제목에 cover, 歌ってみた 같은 단어가 있으면, 영상 설명란에 있는 원곡 링크를 따라가서 원곡의 가사를 사용합니다. 이때 原曲, 本家, original, 원곡 같은 표시가 붙은 링크를 먼저 확인합니다. 원곡 링크가 없으면 영상 제목과 설명란에서 곡 이름과 원곡자를 읽어 LRCLIB에서 찾습니다. 다만 remix, arrange, acoustic, 弾き語り, short ver 같은 편곡 버전이거나 원곡과 길이가 10초 넘게 차이 나면, 가사 타이밍이 맞지 않으므로 원곡 가사를 사용하지 않습니다.
4. **LRCLIB**: 정확 조회(제목, 대체 제목, 정리한 제목으로 최대 3번), 검색, 자유 검색을 차례로 시도하고, 마지막으로 제목과 길이가 같은 결과를 고릅니다.

- 메뉴의 가사 상태에는 가사의 출처가 표시됩니다(예: `YouTube Music · 공식 음원`, `YouTube Music · 원곡`, `LRCLIB · 원곡 검색`).
- 곡이 시작되고 10초가 지나면 Pear 재생목록에 있는 다음 곡의 가사를 미리 찾습니다. 미리 찾을 때 가사를 찾지 못한 곡은 그 곡이 실제로 시작될 때 다시 찾습니다. 가사 서버가 바빠서 미리 찾기에 실패했다면, 지금 곡이 재생되는 동안 30초 뒤와 90초 뒤에 다시 시도합니다.
- LRCLIB에서 찾은 가사는 `~/Library/Caches/PearNowPlaying-macOS/lyrics`에 저장해 둡니다. 같은 곡을 다시 재생하면 LRCLIB에 묻지 않고 저장된 가사를 바로 표시합니다. 저장한 지 90일이 지난 가사는 다시 찾고, 3,000곡을 넘으면 오래된 것부터 지웁니다. **가사 다시 찾기**를 누르면 그 곡의 저장된 가사를 지우고 새로 찾습니다.
- YouTube Music 중계 서버에 보낸 요청이 3번 연달아 실패하면, 그 뒤 10분 동안은 LRCLIB만 사용합니다. **가사 다시 찾기**를 누르면 바로 다시 시도합니다.
- YouTube Music 가사를 먼저 찾는 동작은 메뉴에 없으며 항상 켜져 있습니다. 끄려면 설정 파일의 `ytmLyrics`를 `false`로 바꿉니다.
- 서버 오류가 발생한 결과는 "가사 없음"으로 저장하지 않습니다. YouTube Music 요청이 실패한 상태에서 가사를 찾지 못한 경우에도, 다음에 그 곡을 재생할 때 다시 찾습니다.

메뉴의 **가사 다시 찾기**를 누르면 검색이 진행 중이라는 안내가 화면에 잠시 표시됩니다. 싱크 가사를 찾으면 곡 카드와 가사를 표시하고, 연주곡이거나 일반 가사만 있거나 가사를 찾지 못했거나 연결에 실패한 경우에도 그 결과를 안내 카드로 알려줍니다. 곡 정보를 계속 표시하는 중이라면, 안내 카드는 3.5초 뒤에 다시 곡 카드로 바뀝니다. 검색 도중에 곡이 바뀌면 이전 곡의 검색과 대기는 취소되며, 이전 곡의 결과 안내도 표시하지 않습니다.

LRCLIB가 `429`, `502`, `503`, `504` 응답을 보내면 2초 뒤에 같은 요청을 한 번만 다시 보냅니다. 응답의 `Retry-After` 헤더에 초 단위 대기 시간이 있으면, 그 값을 2초에서 10초 사이로 제한해서 따릅니다. 다시 보낸 요청도 혼잡 응답을 받으면 다른 검색 요청을 연달아 보내지 않고, 15초 뒤와 45초 뒤에 전체 조회를 다시 시도합니다.

## 원본 디자인과 위치

Windows 버전의 `src/Theme.cs`, `src/CardRenderer.cs`, `src/LyricsView.cs`에 정의된 색상과 레이아웃을 macOS 네이티브 렌더러로 옮겼습니다. 카드 배경은 `#242427`, 테두리는 `#33333a`, 강조색은 코랄 `#ff9294`이며, 폰트는 Pretendard JP를 사용합니다. 여백과 모서리 반경은 16pt, 앨범 아트는 60pt이고, 카드 위쪽에 상태와 시간을 표시합니다. 가사 강조선은 현재 줄 옆에만 표시되며, 일시정지하면 회색으로 바뀝니다. macOS에서는 모든 수치를 논리 좌표(pt)로 사용하고 Retina 배율에 맞춰 렌더링합니다.

기본 위치는 Dock과 메뉴 막대를 제외한 화면 영역의 왼쪽 아래이며, 왼쪽과 아래쪽 여백은 각각 24pt입니다. 위치를 바꿔도 가로 여백과 세로 여백은 같은 값을 사용합니다. 이전 버전의 기본 여백인 `40/140`은 업데이트 후 처음 실행할 때 한 번만 `24/24`로 바꾸며, 사용자가 고른 모서리 위치와 직접 수정한 여백은 그대로 유지합니다. 가사가 있으면 가사 카드를 아래쪽 여백에 붙이고, 곡 카드를 가사 카드보다 10pt 위에 배치합니다. 화면 위쪽에 배치한 경우에는 곡 카드가 여백에 붙고, 가사 카드가 그 아래에 이어집니다. 계속 표시를 끄면 곡 카드만 사라지고 가사 카드는 남으며, 곡 카드가 있던 자리를 빈 공간으로 남겨 두지 않습니다.

렌더링 결과는 GUI를 띄우지 않고도 이미지 파일로 확인할 수 있습니다.

```sh
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --render-preview /tmp/pear-preview.png
```

## 설정과 데이터

메뉴의 **설정 파일 열기**를 선택하면 `~/Library/Application Support/PearNowPlaying-macOS/config.json`이 열립니다. 설정을 수정한 뒤에는 **설정 다시 불러오기**를 선택합니다.

| 설정 | 기본값 | 설명 |
|---|---|---|
| `host`, `port` | `127.0.0.1`, `26538` | 로컬 Pear API의 주소입니다. 호스트는 `127.0.0.1` 또는 `localhost`만 사용할 수 있습니다. |
| `position` | `BottomLeft` | `TopLeft`, `TopCenter`, `TopRight`, `BottomLeft`, `BottomCenter`, `BottomRight`, `Custom` 중 하나입니다. `Custom`은 끌어서 옮겨 둔 위치입니다. |
| `customX`, `customY`, `customFromBottom` | `24`, `24`, `true` | 끌어서 옮겨 둔 위치입니다. 화면 영역의 왼쪽 가장자리에서 `customX`(pt), 위쪽(`customFromBottom=false`) 또는 아래쪽 가장자리에서 `customY`(pt)만큼 떨어져 있습니다. |
| `marginX`, `marginY` | `24`, `24` | Dock과 메뉴 막대를 제외한 화면 영역으로부터 떨어진 여백(pt)입니다. |
| `scale`, `panelWidth` | `1`, `420` | 배율(0.5–3)과 기본 카드 너비(260–800pt)입니다. |
| `monitor` | `0` | 화면 목록에서 사용할 화면의 번호이며, 0부터 셉니다. |
| `showSeconds`, `opacity` | `6`, `0.92` | 곡 카드를 잠시 표시하는 시간과 배경의 불투명도입니다. |
| `alwaysShow`, `showLyrics` | `true`, `true` | 곡 카드를 계속 표시할지, 싱크 가사를 표시할지 정합니다. |
| `lyricsOffsetMs` | `300` | 가사 타이밍 보정값(ms)입니다. 양수이면 가사가 더 빨리 표시됩니다. |
| `ytmLyrics` | `true` | YouTube Music 가사를 먼저 찾을지 정합니다. `false`이면 LRCLIB에서만 찾습니다. 메뉴에는 없는 설정입니다. |
| `ytmLyricsProxy` | `https://ytmbrowseproxy.zvz.be/` | YouTube Music 가사 중계 서버의 주소입니다. |
| `lyricsServer` | `https://lrclib.net` | LRCLIB 서버의 주소입니다. |

설정 파일의 키 이름은 바꾸지 않아야 합니다. 값을 읽을 수 없거나 허용 범위를 벗어나는 설정은 기본값으로 바뀝니다. 이전 버전에서 만든 설정 파일에 없는 키는 기본값으로 채웁니다. 연결 토큰은 같은 폴더의 `token.txt`에 저장하며, Windows 버전의 설정과 토큰은 가져오지 않습니다.

이 앱이 통신하는 곳은 다음과 같습니다.

- 로컬 Pear API
- 곡의 앨범 아트 주소(HTTPS)
- `music.youtube.com`: 곡 정보와 가사 ID를 받고, 공식 음원을 찾을 때는 아티스트 페이지와 앨범 페이지를 받습니다.
- `ytmbrowseproxy.zvz.be`: Pear의 YTMusic 가사 제공자가 사용하는 중계 서버입니다. 현재는 `b-ytmbrowseproxy.zvz.be`로 리다이렉트됩니다. 이 서버에는 browseId와 클라이언트 식별값만 보냅니다.
- `www.youtube.com`: 커버곡에서 가사를 찾지 못했을 때, 원곡 링크를 찾기 위해 영상 설명란만 읽습니다.
- `lrclib.net`: 곡 제목, 아티스트, 앨범, 길이를 보냅니다.

외부 가사 서비스에는 Google 계정 쿠키나 로컬 Pear 연결 토큰을 보내지 않습니다. 앱에 포함된 Pretendard JP 폰트의 라이선스(OFL)는 `assets/fonts/PretendardJP-OFL.txt`와 앱의 Resources 폴더에 들어 있습니다.

## 검증

```sh
./macos/build.sh
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --self-test
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --lyrics-tests
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --ytmusic-tests
python3 macos/Tests/mock_pear.py
```

`--lyrics-tests`는 커버곡의 제목과 설명란을 해석한 결과가 Windows 버전(C#)과 같은지 확인하고, YouTube Music, 공식 음원, 원곡, LRCLIB로 이어지는 검색 순서와 캐시 규칙을 모의 응답으로 검증합니다. `--self-test`는 LRC 파서의 다중 타임스탬프, 오프셋, 빈 줄, 현재 가사 위치를 계산하는 기능과 플레이어 상태 및 탐색 처리를 검증합니다. `mock_pear.py`는 Python 표준 라이브러리로 만든 모의 Pear 서버를 띄웁니다. 이 서버는 WebSocket 토큰을 연결 요청의 헤더로 확인하는 Pear 3.11 방식과, 쿼리 파라미터로 확인하는 Pear 3.12 방식을 차례로 흉내 내며, 만료된 토큰으로 WebSocket 연결이 거절되는 상황, 재인증, 첫 곡·위치·재생 이벤트, Bearer 토큰을 사용하는 재생 제어, 다음 곡 조회, 토큰 파일 권한을 검증합니다. 이 테스트들은 외부 서비스나 로그인된 음악 계정을 사용하지 않습니다. 다만 모의 서버 테스트를 실행하려면 로컬 TCP 포트를 열 수 있는 권한이 필요합니다.

GitHub Actions의 `macOS` 워크플로는 universal 앱과 DMG 파일을 빌드하고 위의 테스트를 실행한 뒤, DMG 파일을 아티팩트로 올립니다. GUI 동작, 실제 Pear 권한 확인 창, 전체 화면 위의 배치는 Mac에서 직접 확인해야 합니다.

가사 카드를 표시하려면 YouTube Music의 `cueRange`나 LRCLIB의 `syncedLyrics`처럼 줄마다 시간 정보가 있는 가사가 필요합니다. YouTube Music에서 가사를 받는 경로는 공식 API가 아니므로, 지역, 응답 형식, 중계 서버의 사정에 따라 막힐 수 있습니다. 그러면 LRCLIB로 넘어가서 가사를 찾습니다. `plainLyrics`처럼 시간 정보가 없는 가사만 있으면 Windows 버전과 마찬가지로 가사 카드를 숨기고, 메뉴에 **일반 가사만 있음 · 싱크 가사 없음**을 표시합니다. 네트워크 오류와 가사가 없는 경우는 서로 다른 상태로 표시합니다. **가사 진단 기록 열기**를 선택하면 곡마다 어떤 단계에서 가사를 찾았는지, 또는 찾지 못했는지 확인할 수 있습니다. 이 기록은 설정 폴더의 `lyrics.log`에 저장되며, 가사 전문과 연결 토큰은 기록하지 않습니다.

원본 동작과 실제로 가사를 찾지 못한 원인을 자세히 비교한 내용은 [분석 기록](ORIGINAL-BEHAVIOR-AUDIT.ko.md)에 있습니다.
