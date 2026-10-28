# Now Playing Widget for macOS

이 앱은 Now Playing Widget을 macOS 13 이상에서 실행할 수 있도록 Swift/AppKit으로 만든 네이티브 버전입니다(1.9.4까지의 이름은 Pear Now Playing이었습니다). 브라우저의 YouTube Music과 Pear Desktop API를 Windows 버전과 같은 방식으로 사용하며, 별도의 런타임이나 외부 Swift 패키지가 필요하지 않습니다.

## 빌드 및 실행

빌드하려면 Xcode Command Line Tools와 macOS SDK가 필요합니다. 설치 여부는 `xcrun swift --version`으로 확인할 수 있습니다.

```sh
./macos/build.sh
open 'macos/build/Now Playing Widget.app'
```

기본 빌드는 현재 Mac의 아키텍처(Apple Silicon 또는 Intel)에 맞춰 만들어집니다. `./macos/build.sh --universal`로 빌드하면 두 아키텍처를 모두 담은 앱이 만들어집니다. `--dmg`를 함께 붙이면 설치용 디스크 이미지(`macos/build/NowPlayingWidget-macOS-<버전>.dmg`)도 만들어집니다. 이 DMG를 열면 앱 아이콘과 `Applications` 폴더 바로 가기가 화살표 배경 위에 나란히 표시됩니다. DMG 창의 모양은 [`dmgbuild`](https://github.com/dmgbuild/dmgbuild)로 만들며, 처음 `--dmg`로 빌드할 때 `macos/build/dmg-venv`에 설치되므로 그때는 인터넷 연결이 필요합니다. 릴리스에는 `./macos/build.sh --universal --dmg`로 만든 DMG 파일을 올립니다.

앱 아이콘(`macos/Resources/AppIcon.icns`)과 DMG 배경(`macos/Resources/dmg-background.tiff`)은 `xcrun swift macos/Tools/make-art.swift`로 그립니다. 그린 결과 파일은 저장소에 들어 있으므로, 디자인을 바꿀 때만 이 스크립트를 실행하면 됩니다. 빌드 결과는 `macos/build/Now Playing Widget.app`에 생성되고, 원하는 Applications 폴더로 복사해서 사용할 수 있습니다. 앱에는 개발용 ad-hoc 서명만 되어 있으며, Apple의 공증은 받지 않았습니다.

1. 이 앱을 실행합니다. 상태와 설정은 메뉴 막대의 음표 아이콘에서 확인할 수 있습니다. 이 앱은 Dock에 표시되지 않습니다.
2. 브라우저에서 YouTube Music을 재생하면 곡 카드가 나타납니다. 처음에는 macOS가 이 앱이 브라우저를 제어하도록 허용할지 묻습니다. **허용**을 누르면 YouTube Music 탭의 주소를 읽어서 곡을 정확히 알아냅니다(아래 "브라우저 연동" 참고).
3. Pear Desktop을 함께 쓴다면 Pear Desktop의 **플러그인 → API 서버 [베타]**를 켭니다. 호스트는 `127.0.0.1`, 포트는 `26538`으로 설정하는 것을 권장합니다. 그다음 메뉴의 **Pear Desktop 연결 요청**을 누르고, Pear에 나타나는 `pear-now-playing-macos` 연결 요청을 **허용**합니다(이름은 이전 이름 그대로입니다). 위젯은 이 메뉴를 누르기 전에는 Pear에 연결을 요청하지 않으며, 한 번 연결해 두면 그 뒤로는 자동으로 연결됩니다.

API 서버가 꺼져 있어도 메뉴에서 **Pear Desktop 연결 요청**을 선택하면 됩니다. 이 메뉴를 선택하면 앱은 음악 앱의 `config.json`을 백업한 뒤 API 서버를 켜고, 호스트를 `127.0.0.1`로, 포트를 위젯 설정과 같은 값으로 저장합니다. 또한 로컬 HTTP 연결을 사용하도록 `useHttps`를 끄며, 기존의 인증 정책과 다른 플러그인 설정은 그대로 유지합니다. 이 기능이 지원하는 설정 폴더는 `YouTube Music`, `Pear Desktop`, `pear-desktop`입니다.

설정을 저장한 뒤에는 연결을 다시 시도합니다. 실행 중인 음악 앱에 변경 사항이 바로 반영되지 않으면, 앱이 **음악 앱 다시 시작** 버튼을 보여줍니다. 음악 앱을 다시 시작하면 재생 중인 음악이 잠시 멈춥니다. 쓰기 권한이 없거나 설정 파일에 문제가 있으면 앱이 오류 메시지를 표시합니다. API 서버가 이미 켜져 있는 상태에서도 같은 메뉴로 연결 권한을 다시 요청할 수 있습니다.

음악 앱 없이 화면 표시만 확인하려면, 실행 중인 Now Playing Widget을 메뉴에서 종료한 뒤 아래 명령을 실행합니다.

```sh
open 'macos/build/Now Playing Widget.app' --args --preview
```

미리보기 모드는 실제 음악 앱에 연결하지 않습니다. 일반 모드로 돌아가려면 앱을 종료한 뒤 다시 실행합니다.

## 브라우저 연동

웹 브라우저에서 재생하는 YouTube Music을 확장 프로그램 없이 표시합니다. 동작은 Windows 버전과 같으며, 곡을 읽는 방법만 macOS에 맞췄습니다.

- **재생 정보**: macOS의 "지금 재생 중" 정보(MediaRemote)에서 제목, 아티스트, 재생 위치, 재생 상태, 재생 중인 앱을 1초마다 읽습니다. macOS 15.4부터 이 정보는 Apple이 허용한 프로그램에만 제공되므로, 앱에 들어 있는 작은 라이브러리(`Contents/Frameworks/libnowplaying.dylib`, 소스는 `macos/Helper/NowPlaying.m`)를 macOS에 기본으로 들어 있는 `/usr/bin/perl`이 불러와서 읽습니다. 따로 허용할 권한은 없습니다.
- **곡 알아내기**: 재생 중인 앱이 브라우저이면, `osascript`로 그 브라우저의 `music.youtube.com` 탭 주소와 제목만 읽어서 영상 ID를 얻습니다. 걸러내는 조건이 스크립트 안에 있으므로 다른 탭의 주소는 브라우저 밖으로 나오지 않습니다. 처음 읽을 때 **"Now Playing Widget"이(가) "Google Chrome"을(를) 제어하려고 합니다** 같은 창이 나타나며, 브라우저마다 한 번씩 **허용**합니다. 창이 다른 화면에 떠서 응답을 기다리는 동안에는 위젯에 안내가 나타납니다. 허용 여부는 **시스템 설정 → 개인정보 보호 및 보안 → 자동화**에서 바꿀 수 있습니다.
- **지원하는 브라우저**: Chrome, Edge, Brave, Arc, Whale, Vivaldi, Opera, Safari는 탭 주소를 읽습니다. Firefox처럼 탭을 읽을 수 없는 브라우저나 자동화 권한을 거부한 브라우저는 제목, 아티스트, 길이로 YouTube를 검색해서 영상을 찾습니다.
- **재생 앱**: 메뉴의 **재생 앱**에서 자동(기본값), 브라우저, Pear Desktop 중에서 고릅니다. 자동이면 나중에 재생을 시작한 쪽의 곡을 표시합니다.
- **다음 곡 가사 미리 찾기**: 탭이 재생 중인 앨범이나 재생목록의 순서로 다음 곡을 추정합니다. 셔플이나 라디오에서 추정이 틀리면, 그 목록은 다시 맞을 때까지 미리 찾지 않습니다.
- **재생 제어**: 메뉴와 단축키의 재생/일시정지, 다음 곡, 이전 곡은 macOS의 미디어 명령으로 브라우저에 보냅니다.
- **Discord**: 메뉴의 **Discord → 듣는 중 표시**를 켜면 듣는 곡(브라우저와 Pear Desktop)을 Discord 프로필에 "듣는 중"으로 표시합니다(처음에는 꺼져 있음). Discord 앱의 로컬 소켓(`$TMPDIR/discord-ipc-N`)으로 보냅니다. 제목과 앨범 아트를 누르면 YouTube Music에서 그 곡이 열리고, **GitHub 버튼 표시**로 이 앱의 GitHub 페이지 버튼을 붙이거나 뗄 수 있습니다.

## 기능

- 오버레이는 포커스를 가져가지 않으며, 클릭과 키 입력을 아래에 있는 앱으로 그대로 전달합니다. 모든 데스크톱 공간과 전체 화면 공간에 표시됩니다.
- 곡이 바뀌거나 재생 상태가 바뀌면 앨범 아트, 아티스트·앨범, 실시간 진행 바를 표시하고, 긴 제목은 스크롤합니다.
- 가사는 Windows 1.5.0과 같은 순서로 찾습니다: YouTube Music 가사, MV라면 공식 음원의 가사, 커버곡이라면 원곡의 가사, 마지막으로 LRCLIB 순서입니다.
- LRCLIB 검색 순서도 Windows 버전과 같습니다. 대체 제목과 정리한 제목으로 검색하고, 아티스트·태그의 유사도와 재생 길이로 결과를 확인하며, 결과를 캐시하고, 네트워크 오류가 나면 다시 시도합니다.
- 다음 곡의 가사를 미리 찾아 둡니다(Pear는 재생목록, 브라우저는 앨범이나 재생목록의 순서).
- **위젯 → 영상 곡 제목**에서 앨범 곡이 아닌 영상(MV, 커버, 일반 업로드)에 곡 제목(기본값)과 영상 제목(Pear의 Discord 상태와 같은 제목) 중 무엇을 표시할지 고를 수 있습니다.
- 번역 제목만 표시되는 앨범 곡(예: `Only Words`)은 YouTube Music의 재생목록 정보를 확인해서 **원제 - 번역** 형식(`心を刺す言葉だけ - Only Words`)으로 보여줍니다. Windows 버전과 같은 규칙입니다.
- 현재 가사 줄을 강조하면서 스크롤하고, 가사 타이밍을 보정할 수 있으며, 한국어와 일본어를 Pretendard JP 폰트로 표시합니다.
- 메뉴 막대에서 재생을 제어할 수 있습니다. 설정은 **위젯** 메뉴(곡 정보 계속 표시, 영상 곡 제목, 표시, 위치, 크기, 투명도, Liquid Glass 배경(beta), 위젯 끌어서 옮기기)와 **가사** 메뉴(가사 표시, 커버곡 가사 표시(beta), 가사 다시 찾기, 이 곡 가사 타이밍, 모든 곡 가사 타이밍)로 나뉘어 있습니다. 메뉴 구성은 Windows 버전과 같습니다. 가사 타이밍 메뉴는 항목을 눌러도 닫히지 않으므로, 가사를 보면서 여러 번 눌러 맞출 수 있습니다.
- **위젯 끌어서 옮기기**를 켜면 각 화면의 위젯을 마우스로 끌어서 그 화면 안의 원하는 곳에 놓을 수 있고, 다시 누르면 끝납니다. 평소에는 위젯이 클릭을 통과시키기 때문에 이 항목이 켜져 있는 동안에만 끌 수 있습니다. 화면의 아래쪽 절반에 놓으면 가사 카드가 아래에 고정되고, 위쪽 절반에 놓으면 곡 카드가 위에 고정됩니다. 놓은 위치는 그 화면의 **직접 옮긴 위치**로 저장됩니다.
- 새 버전이 있으면 알려주고, 메뉴 맨 위의 **(버전) 설치** 버튼을 누르면 직접 설치합니다(아래 "업데이트" 참고).
- 화면이 여러 개이면 **위젯 → 표시**에서 위젯을 띄울 화면을 켜고 끄며, 여러 화면에 동시에 띄울 수 있습니다. **위치**, **크기**, **투명도**는 위젯마다 따로 정합니다. 동작은 Windows 버전과 같습니다.
- 토큰이 만료되면 다시 인증하고, 연결이 끊기면 다시 접속합니다. 토큰 파일의 권한은 `0600`으로 저장합니다.

macOS의 창 관리 정책 때문에, 일부 독점 전체 화면 앱 위에서는 오버레이가 보이지 않을 수 있습니다.

| 단축키 | 기능 |
|---|---|
| `Control + Option + ↑` | 지금 곡 보기 |
| `Control + Option + ↓` | 재생 / 일시정지 |
| `Control + Option + →` | 다음 곡 |
| `Control + Option + ←` | 이전 곡 |
| `Control + Option + P` | 곡 정보 계속 표시 켜기/끄기 |
| `Control + Option + L` | 가사 표시 켜기/끄기 |

단축키는 Carbon 전역 단축키 API로 등록하므로 손쉬운 사용(접근성) 권한이 필요하지 않습니다. 단축키는 설정 파일의 `hotkeyShow`, `hotkeyToggle`, `hotkeyNext`, `hotkeyPrevious`, `hotkeyAlwaysShow`, `hotkeyLyrics`에서 바꿀 수 있고, 값을 비워 두면 그 단축키를 사용하지 않습니다. 형식은 Windows 버전과 같습니다(예: `Ctrl+Alt+Up`, `Ctrl+Shift+F9`). `Ctrl`은 Control, `Alt`는 Option, `Win`(또는 `Cmd`)은 Command 키입니다. 다른 앱이 이미 사용 중인 조합은 등록되지 않으며, 그때는 "단축키를 등록하지 못했습니다" 안내가 표시되고 오류 기록에도 남습니다.

## 가사

가사는 Windows 1.5.0(`src/Lyrics.cs`, `src/YtmLyrics.cs`, `src/CoverLyrics.cs`)과 같은 순서로 찾습니다.

1. **YouTube Music**: 재생 중인 영상의 싱크 가사를 Pear의 YTMusic 가사 제공자와 같은 중계 서버(`ytmbrowseproxy.zvz.be`)를 통해 받습니다. 로그인하지 않은 상태로 YouTube Music에 직접 요청하면 가사를 받을 수 없으므로, 직접 요청은 보내지 않습니다.
2. **공식 음원**: 싱크 가사는 대부분 공식 음원에만 제공됩니다. 그래서 MV를 재생할 때는 YouTube Music의 아티스트 페이지(필요하면 전체 디스코그래피)에서 같은 제목의 싱글이나 앨범을 찾고, 길이 차이가 5초 이내인 공식 음원의 가사를 대신 사용합니다.
3. **커버곡**: 개인이 업로드한 영상이거나 제목에 cover, 歌ってみた 같은 단어가 있으면, 영상 설명란에 있는 원곡 링크를 따라가서 원곡의 가사를 사용합니다. 이때 原曲, 本家, original, 원곡 같은 표시가 붙은 링크를 먼저 확인합니다. 쓸 수 있는 원곡 링크가 없으면 곡 이름으로 YouTube를 검색해서 공식 채널의 원곡 영상을 찾고(아티스트가 하나로 정해질 때만), 그래도 없으면 영상 제목과 설명란에서 곡 이름과 원곡자를 읽어 LRCLIB에서 찾습니다. 다만 remix, arrange, acoustic, 弾き語り, short ver 같은 편곡 버전이거나 원곡과 길이가 10초 넘게 차이 나면, 가사 타이밍이 맞지 않으므로 원곡 가사를 사용하지 않습니다.
4. **LRCLIB**: 정확 조회(제목, 대체 제목, 정리한 제목으로 최대 3번), 검색, 자유 검색을 차례로 시도하고, 마지막으로 제목과 길이가 같은 결과를 고릅니다.
5. **Kugou, NetEase(网易云音乐)**: LRCLIB에 싱크 가사가 없거나, LRCLIB가 요청 제한(429)으로 답할 때만 차례로 묻습니다. 제목이 같고 아티스트가 같으며 길이 차이가 15초 이내인 결과만 사용합니다(아티스트 표기가 다르면 제목이 정확히 같고 길이 차이가 3초 이내여야 합니다). 두 곳 모두 공식 API가 아니므로, 한 곳에 보낸 요청이 3번 연달아 실패하면 그곳은 10분 동안 묻지 않습니다. 커버곡의 원곡을 찾을 때도 LRCLIB 다음에 이 두 곳을 봅니다.

- 메뉴의 가사 상태에는 가사의 출처가 표시됩니다(예: `YouTube Music · 공식 음원`, `YouTube Music · 원곡`, `LRCLIB · 원곡 검색`, `Kugou`, `NetEase · 원곡`).
- 곡이 시작되고 10초가 지나면 다음 곡의 가사를 미리 찾습니다. 미리 찾을 때 가사를 찾지 못한 곡은 그 곡이 실제로 시작될 때 다시 찾습니다. 가사 서버가 바빠서 미리 찾기에 실패했다면, 지금 곡이 재생되는 동안 30초 뒤와 90초 뒤에 다시 시도합니다.
- LRCLIB에서 찾은 가사와, LRCLIB에 없어서 Kugou나 NetEase에서 찾은 가사는 `~/Library/Caches/PearNowPlaying-macOS/lyrics`에 저장해 둡니다. LRCLIB의 요청 제한(429) 때문에 대신 찾은 가사는 먼저 표시해 두고, 곡이 재생되는 동안 LRCLIB에 계속 다시 묻습니다. LRCLIB에 가사가 있으면 그 가사로 바꾸고, LRCLIB가 "없음"이라고 답하면 지금 가사를 그대로 두고 저장합니다. 끝까지 LRCLIB가 답하지 못하면 저장하지 않고, 다음 실행에서 LRCLIB에 다시 묻습니다. Kugou나 NetEase에서 찾아 저장한 곡은, 그사이 LRCLIB에 가사가 올라왔을 수 있으므로 다시 재생할 때 저장된 가사를 먼저 표시하고 LRCLIB에만 다시 묻습니다. LRCLIB에 가사가 생겼으면 그 가사로 바꿔서 저장합니다. LRCLIB는 같은 질문의 답을 하루 동안 보관하므로, 앱을 켜 둔 채로 같은 곡을 다시 들을 때는 하루에 한 번만 묻습니다. 같은 곡을 다시 재생하면 가사 서버에 묻지 않고 저장된 가사를 바로 표시합니다. 저장한 지 90일이 지난 가사는 다시 찾고, 3,000곡을 넘으면 오래된 것부터 지웁니다. **가사 다시 찾기**를 누르면 그 곡의 저장된 가사를 지우고 새로 찾습니다.
- YouTube Music 중계 서버에 보낸 요청이 3번 연달아 실패하면, 그 뒤 10분 동안은 LRCLIB만 사용합니다. **가사 다시 찾기**를 누르면 바로 다시 시도합니다.
- YouTube Music 가사를 먼저 찾는 동작은 메뉴에 없으며 항상 켜져 있습니다. 끄려면 설정 파일의 `ytmLyrics`를 `false`로 바꿉니다.
- 서버 오류가 발생한 결과는 "가사 없음"으로 저장하지 않습니다. YouTube Music, Kugou, NetEase 요청이 실패한 상태에서 가사를 찾지 못한 경우에도, 다음에 그 곡을 재생할 때 다시 찾습니다.

메뉴의 **가사 다시 찾기**를 누르면 검색이 진행 중이라는 안내가 화면에 잠시 표시됩니다. 싱크 가사를 찾으면 곡 카드와 가사를 표시하고, 연주곡이거나 가사를 찾지 못했거나 연결에 실패한 경우에도 그 결과를 안내 카드로 알려줍니다. 곡 정보를 계속 표시하는 중이라면, 안내 카드는 3.5초 뒤에 다시 곡 카드로 바뀝니다. 검색 도중에 곡이 바뀌면 이전 곡의 검색과 대기는 취소되며, 이전 곡의 결과 안내도 표시하지 않습니다.

LRCLIB의 [API 문서](https://lrclib.net/docs)가 정한 규칙을 따릅니다. 요청은 하나씩 보내고 요청 사이에 0.3초 이상 간격을 두며, 앱 전체에서 1분에 60번을 넘기지 않습니다(이름을 밝힌 클라이언트의 허용량은 IP당 1분에 약 90번입니다). LRCLIB가 `502`, `503`, `504`(바쁨)로 답하면 `Retry-After` 헤더의 시간(없으면 1초)에 0–30%의 무작위 시간을 더한 만큼 모든 LRCLIB 요청을 쉬고 다시 보냅니다. 바쁜 동안에는 Kugou와 NetEase에 묻지 않고, 곡이 재생되는 동안 최대 10분까지 LRCLIB에 계속 다시 묻습니다. LRCLIB가 `429`(요청이 너무 많음)로 답하면 `Retry-After` 동안 LRCLIB 요청을 모두 멈추고, 그동안 Kugou와 NetEase에서 찾은 가사를 먼저 표시한 뒤 시간이 지나면 LRCLIB에 다시 묻습니다. 바쁨 응답이 아닌 오류(연결 끊김 등)일 때는 15초마다 다시 시도합니다. `Retry-After`가 30초보다 길면 이번 조회는 바로 끝내고, 그 시간이 지날 때까지 LRCLIB에 요청을 보내지 않습니다.

## 업데이트

1.6.0부터는 앱이 새 버전을 직접 확인하고 설치합니다. 동작은 Windows 버전과 같습니다.

- 앱을 켜고 30초 뒤와, 그 뒤 하루에 한 번 GitHub의 최신 릴리스를 확인합니다. 새 버전이 있으면 안내가 잠시 표시되고, 메뉴 맨 위의 버튼이 **(버전) 설치**로 바뀝니다. 같은 버튼이 평소에는 **업데이트 확인**이며, 누르면 메뉴가 열린 채로 확인하고 결과를 버튼에 표시합니다.
- 설치는 메뉴 맨 위의 **(버전) 설치** 버튼을 눌렀을 때만 진행합니다.
- 설치할 때는 DMG를 받아서 GitHub가 함께 알려주는 SHA-256 값과 비교하고, 화면에 띄우지 않고 마운트해서 앱의 서명, 번들 ID, 버전을 확인합니다. 그다음 지금 앱을 새 앱으로 바꾸고, 앱이 종료되면 다시 실행합니다.
- 앱이 직접 받은 파일에는 격리 표시가 붙지 않으므로, "그래도 열기"를 다시 누를 필요가 없습니다.
- 앱을 바꿀 권한이 없으면(다른 사용자가 설치한 앱이거나, DMG에서 바로 실행한 경우 등) 지금 앱을 그대로 두고 받은 DMG를 엽니다. 그때는 직접 끌어다 놓아 설치합니다.
- 자동 확인을 끄려면 설정 파일의 `checkUpdates`를 `false`로 바꿉니다.
- 1.9.4까지의 앱(`Pear Now Playing.app`)을 업데이트하면, 같은 폴더에 `Now Playing Widget.app`으로 이름을 바꿔서 설치합니다. 번들 ID는 그대로이므로 설정, Pear 연결 권한, 자동화 권한은 이어집니다.

## 원본 디자인과 위치

Windows 버전의 `src/Theme.cs`, `src/CardRenderer.cs`, `src/LyricsView.cs`에 정의된 색상과 레이아웃을 macOS 네이티브 렌더러로 옮겼습니다. 카드 배경은 `#242427`, 테두리는 `#33333a`, 강조색은 코랄 `#ff9294`이며, 폰트는 Pretendard JP를 사용합니다. 여백과 모서리 반경은 16pt, 앨범 아트는 60pt이고, 카드 위쪽에 상태와 시간을 표시합니다. 가사 강조선은 현재 줄 옆에만 표시되며, 일시정지하면 회색으로 바뀝니다. macOS에서는 모든 수치를 논리 좌표(pt)로 사용하고 Retina 배율에 맞춰 렌더링합니다.

기본 위치는 Dock과 메뉴 막대를 제외한 화면 영역의 왼쪽 아래이며, 왼쪽과 아래쪽 여백은 각각 24pt입니다. 위치를 바꿔도 가로 여백과 세로 여백은 같은 값을 사용합니다. 이전 버전의 기본 여백인 `40/140`은 업데이트 후 처음 실행할 때 한 번만 `24/24`로 바꾸며, 사용자가 고른 모서리 위치와 직접 수정한 여백은 그대로 유지합니다. 가사가 있으면 가사 카드를 아래쪽 여백에 붙이고, 곡 카드를 가사 카드보다 10pt 위에 배치합니다. 화면 위쪽에 배치한 경우에는 곡 카드가 여백에 붙고, 가사 카드가 그 아래에 이어집니다. 계속 표시를 끄면 곡 카드만 사라지고 가사 카드는 남으며, 곡 카드가 있던 자리를 빈 공간으로 남겨 두지 않습니다.

렌더링 결과는 GUI를 띄우지 않고도 이미지 파일로 확인할 수 있습니다.

```sh
'macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget' --render-preview /tmp/widget-preview.png
```

## 설정과 데이터

메뉴의 **설정 파일 열기**를 선택하면 `~/Library/Application Support/PearNowPlaying-macOS/config.json`이 열립니다(폴더 이름은 이전 이름을 그대로 씁니다). 설정을 수정한 뒤에는 **설정 다시 불러오기**를 선택합니다.

| 설정 | 기본값 | 설명 |
|---|---|---|
| `source` | `auto` | 곡을 가져올 곳입니다. `auto`(브라우저와 Pear Desktop 중 나중에 재생을 시작한 쪽), `browser`, `pear` 중 하나입니다. |
| `discordPresence`, `discordButton` | `false`, `true` | 듣는 곡을 Discord에 "듣는 중"으로 표시할지, 거기에 GitHub 페이지 버튼을 붙일지 정합니다. |
| `host`, `port` | `127.0.0.1`, `26538` | 로컬 Pear API의 주소입니다. 호스트는 `127.0.0.1` 또는 `localhost`만 사용할 수 있습니다. |
| `widgets` | 주 화면 왼쪽 아래 하나 | 위젯 목록입니다. 항목마다 `monitor`(화면 번호, 0부터), `position`(`TopLeft` … `BottomRight` 또는 `Custom`), `customX`, `customY`, `customFromBottom`(끌어서 옮겨 둔 위치, pt), `scale`(그 위젯의 배율, 없으면 아래의 `scale`), `transparency`(위젯 전체의 투명도, 0–0.8), `hidden`(**표시**에서 끈 위젯이면 `true`, 설정은 보관됨)이 있습니다. 1.6까지의 `position`, `monitor`, `custom…` 값은 처음 실행할 때 이 목록으로 옮겨집니다. |
| `marginX`, `marginY` | `24`, `24` | Dock과 메뉴 막대를 제외한 화면 영역으로부터 떨어진 여백(pt)입니다. |
| `scale`, `panelWidth` | `1`, `420` | 배율(0.5–3, `scale`이 없는 위젯에 적용)과 기본 카드 너비(260–800pt)입니다. |
| `showSeconds`, `opacity` | `6`, `0.92` | 곡 카드를 잠시 표시하는 시간과 배경의 불투명도입니다. |
| `showOnPause` | `true` | 일시정지하거나 다시 재생할 때도 곡 카드를 잠시 표시할지 정합니다. |
| `showAlbumArt` | `true` | 앨범 아트를 표시할지 정합니다. |
| `alwaysShow`, `showLyrics` | `true`, `true` | 곡 카드를 계속 표시할지, 싱크 가사를 표시할지 정합니다. |
| `checkUpdates` | `true` | 시작할 때와 하루에 한 번 새 버전이 있는지 GitHub에서 확인합니다. 설치는 메뉴에서 직접 누를 때만 합니다. |
| `coverLyrics` | `true` | 메뉴의 "커버곡 가사 표시(beta)"입니다. `false`이면 앨범 곡(공식 음원)에서만 가사를 찾아 표시하고, 커버·MV·일반 업로드 영상에서는 찾지 않습니다. 2.0.2까지의 `"lyricsAlbumOnly": true`(앨범 곡만 가사 표시)는 `"coverLyrics": false`로 이어집니다. |
| `liquidGlass` | `off` | 메뉴의 "Liquid Glass 배경(beta)"입니다. `regular` 또는 `clear`이면 카드의 어두운 배경 대신 macOS 26의 Liquid Glass를 씁니다. `clear`가 더 투명합니다. 글자가 밝은 화면에서도 보이도록 유리 위에 어두운 색을 조금 깔며, 그 정도는 `opacity`를 따릅니다. macOS 26보다 낮은 버전에서는 메뉴에서 고를 수 없고, Windows 버전에는 없는 설정입니다. |
| `videoTitle` | `song` | 앨범 곡이 아닌 영상에 표시할 제목입니다. `song`은 곡 제목, `video`는 영상 제목(Pear의 Discord 상태와 같은 제목)입니다. |
| `lyricsOffsetMs` | `300` | 모든 곡의 가사 타이밍 보정값(ms)입니다. 양수이면 가사가 더 빨리 표시됩니다. 메뉴의 **모든 곡 가사 타이밍**에서 0.1초나 0.5초씩 바꾸며, 메뉴에는 기본값(300)과의 차이로 표시됩니다. 영상마다 맞춘 값(**이 곡 가사 타이밍**)은 같은 폴더의 `lyrics-timing.json`에 저장되고, 이 값에 더해집니다. |
| `hotkey...` | 위 단축키 표 참고 | 단축키입니다. 값을 비워 두면 그 단축키를 사용하지 않습니다. |
| `ytmLyrics` | `true` | YouTube Music 가사를 먼저 찾을지 정합니다. `false`이면 LRCLIB에서만 찾습니다. 메뉴에는 없는 설정입니다. |
| `ytmLyricsProxy` | `https://ytmbrowseproxy.zvz.be/` | YouTube Music 가사 중계 서버의 주소입니다. |
| `lyricsServer` | `https://lrclib.net` | LRCLIB 서버의 주소입니다. |
| `moreLyrics` | `true` | LRCLIB에 싱크 가사가 없을 때 Kugou와 NetEase에서도 찾을지 정합니다. 메뉴에는 없는 설정입니다. |

설정 파일의 키 이름은 바꾸지 않아야 합니다. 값을 읽을 수 없거나 허용 범위를 벗어나는 설정은 기본값으로 바뀝니다. 이전 버전에서 만든 설정 파일에 없는 키는 기본값으로 채웁니다. 연결 토큰은 같은 폴더의 `token.txt`에 저장하며, Windows 버전의 설정과 토큰은 가져오지 않습니다.

이 앱이 통신하는 곳은 다음과 같습니다.

- 로컬 Pear API
- 이 Mac 안에서만: macOS의 "지금 재생 중" 정보(`/usr/bin/perl`이 읽음), 브라우저의 `music.youtube.com` 탭 주소와 제목(`osascript`), Discord 앱(듣는 중 표시를 켰을 때만)
- 곡의 앨범 아트 주소(HTTPS). Discord 상태를 켰다면 Discord도 이 주소의 이미지를 받아 갑니다.
- `music.youtube.com`: 곡 정보와 가사 ID를 받고, 공식 음원을 찾을 때는 아티스트 페이지와 앨범 페이지를 받습니다.
- `ytmbrowseproxy.zvz.be`: Pear의 YTMusic 가사 제공자가 사용하는 중계 서버입니다. 현재는 `b-ytmbrowseproxy.zvz.be`로 리다이렉트됩니다. 이 서버에는 browseId와 클라이언트 식별값만 보냅니다.
- `www.youtube.com`: 커버곡의 원곡을 찾을 때 영상 설명란을 읽고, 원곡 링크가 없으면 곡 이름으로 검색합니다. 브라우저에서 듣는 곡의 탭 주소를 읽지 못했을 때는 제목과 아티스트로 검색합니다.
- `lrclib.net`: 곡 제목, 아티스트, 앨범, 길이를 보냅니다.
- `lyrics.kugou.com`, `music.163.com`(`moreLyrics`가 켜져 있고 LRCLIB에서 싱크 가사를 찾지 못했을 때만): 곡 제목, 아티스트, 길이를 보내고 가사를 받습니다. 각 서비스의 앱이 사용하는 비공식 경로이며, 로그인 정보는 보내지 않습니다.
- `api.github.com`, `github.com`: 새 버전을 확인하고, 업데이트를 설치할 때 릴리스 파일을 받습니다. 앱 버전 외의 정보는 보내지 않습니다.

외부 가사 서비스에는 Google 계정 쿠키나 로컬 Pear 연결 토큰을 보내지 않습니다. 앱에 포함된 Pretendard JP 폰트의 라이선스(OFL)는 `assets/fonts/PretendardJP-OFL.txt`와 앱의 Resources 폴더에 들어 있습니다.

## 검증

```sh
./macos/build.sh
'macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget' --self-test
'macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget' --lyrics-tests
'macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget' --ytmusic-tests
python3 macos/Tests/mock_pear.py
python3 macos/Tests/mock_update.py
python3 macos/Tests/mock_discord.py
```

README의 GIF는 `--render-demo <폴더>`가 그린 프레임을 `python3 macos/Tools/make-gifs.py`가 묶어서 만듭니다. 실제 브라우저와 곡으로 확인할 때는 실행 파일에 `--browser-probe [초]`(브라우저 연동이 읽는 값과 보내는 메시지 출력)나 `--lookup <영상 ID>`(한 곡의 가사 찾기 과정을 로그와 함께 출력)를 붙여 실행합니다.

`--lyrics-tests`는 커버곡의 제목과 설명란을 해석한 결과가 Windows 버전(C#)과 같은지 확인하고, YouTube Music, 공식 음원, 원곡, LRCLIB로 이어지는 검색 순서와 캐시 규칙을 모의 응답으로 검증합니다. `--self-test`는 LRC 파서의 다중 타임스탬프, 오프셋, 빈 줄, 현재 가사 위치를 계산하는 기능과 플레이어 상태 및 탐색 처리를 검증합니다. `mock_discord.py`는 가짜 Discord 소켓으로 "듣는 중" 표시의 내용과 보내는 간격을 확인합니다. `mock_update.py`는 이전 이름(`Pear Now Playing.app`)으로 설치된 앱이 새 이름으로 바뀌는지와 이전 이름의 릴리스 파일도 받는지 확인합니다. `mock_pear.py`는 Python 표준 라이브러리로 만든 모의 Pear 서버를 띄웁니다. 이 서버는 WebSocket 토큰을 연결 요청의 헤더로 확인하는 Pear 3.11 방식과, 쿼리 파라미터로 확인하는 Pear 3.12 방식을 차례로 흉내 내며, 만료된 토큰으로 WebSocket 연결이 거절되는 상황, 재인증, 첫 곡·위치·재생 이벤트, Bearer 토큰을 사용하는 재생 제어, 다음 곡 조회, 토큰 파일 권한을 검증합니다. 이 테스트들은 외부 서비스나 로그인된 음악 계정을 사용하지 않습니다. 다만 모의 서버 테스트를 실행하려면 로컬 TCP 포트를 열 수 있는 권한이 필요합니다.

GitHub Actions의 `macOS` 워크플로는 universal 앱과 DMG 파일을 빌드하고 위의 테스트를 실행한 뒤, DMG 파일을 아티팩트로 올립니다. GUI 동작, 실제 Pear 권한 확인 창, 전체 화면 위의 배치는 Mac에서 직접 확인해야 합니다.

가사 카드를 표시하려면 YouTube Music의 `cueRange`나 LRCLIB의 `syncedLyrics`처럼 줄마다 시간 정보가 있는 가사가 필요합니다. YouTube Music에서 가사를 받는 경로는 공식 API가 아니므로, 지역, 응답 형식, 중계 서버의 사정에 따라 막힐 수 있습니다. 그러면 LRCLIB로 넘어가서 가사를 찾습니다. `plainLyrics`처럼 시간 정보가 없는 가사만 있으면 Windows 버전과 마찬가지로 가사 카드를 숨기고, 메뉴의 가사 상태에 **가사: 찾지 못함**을 표시합니다. 네트워크 오류와 가사가 없는 경우는 서로 다른 상태로 표시합니다. 메뉴의 **오류 기록 열기**를 선택하면 기록 파일(`~/Library/Application Support/PearNowPlaying-macOS/error.log`)이 열립니다. Windows 버전의 `error.log`와 같은 형식이며, 곡마다 어떤 단계에서 가사를 찾았는지(또는 찾지 못했는지), Pear 연결이 끊긴 이유(종료 코드, HTTP 상태, 오류 코드), 연결 권한을 다시 받은 시점, 재생 제어나 앨범 아트 오류가 기록됩니다. 같은 연결 실패가 반복되면 처음 한 번만 기록합니다. 512KB를 넘으면 새로 시작하며, 가사 전문과 연결 토큰은 기록하지 않습니다. 1.5.2까지 쓰던 `lyrics.log`는 처음 실행할 때 `error.log`로 이어집니다.

원본 동작과 실제로 가사를 찾지 못한 원인을 자세히 비교한 내용은 [분석 기록](ORIGINAL-BEHAVIOR-AUDIT.ko.md)에 있습니다.
