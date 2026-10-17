# Pear Now Playing for macOS

macOS 13 이상에서 실행되는 네이티브 Swift/AppKit 포트입니다. Windows 소스와 같은 Pear Desktop API를 사용하며 별도 런타임이나 외부 Swift 패키지가 필요하지 않습니다.

## 빌드 및 실행

Xcode Command Line Tools와 macOS SDK가 필요합니다. `xcrun swift --version`으로 확인할 수 있습니다.

```sh
./macos/build.sh
open 'macos/build/Pear Now Playing.app'
```

빌드는 현재 Mac의 아키텍처(Apple Silicon 또는 Intel)에 맞춥니다. 결과는 `macos/build/Pear Now Playing.app`이며 원하는 Applications 폴더로 복사할 수 있습니다. 개발용 ad-hoc 서명이며 Apple 공증은 포함하지 않습니다.

1. Pear Desktop 또는 호환되는 YouTube Music 데스크톱 앱을 엽니다.
2. **플러그인 → API 서버 [베타]**를 켭니다. 호스트는 `127.0.0.1`, 포트는 `26538`을 권장합니다.
3. 이 앱을 실행한 뒤 Pear에 뜨는 `pear-now-playing-macos` 연결 요청을 **허용**합니다.
4. 음악을 재생하면 곡 카드가 나타납니다. 메뉴 막대의 음표 아이콘에서 상태와 설정을 확인합니다. Dock에는 표시되지 않습니다.

API 서버가 꺼져 있으면 메뉴에서 **Pear 연결 권한 다시 요청**을 선택합니다. 이 메뉴는 음악 앱의 `config.json`을 백업하고 API 서버를 켜며, 호스트를 `127.0.0.1`, 포트를 위젯의 설정과 같은 값으로 저장합니다. 로컬 HTTP 연결을 사용하도록 `useHttps`를 끄고 기존 인증 정책 및 다른 플러그인 설정은 유지합니다. 지원하는 설정 폴더는 `YouTube Music`, `Pear Desktop`, `pear-desktop`입니다.

설정 저장 후 연결을 재시도합니다. 실행 중인 음악 앱에 바로 반영되지 않으면 **음악 앱 다시 시작** 버튼을 제공합니다. 재시작하면 재생 중인 음악이 잠시 멈춥니다. 쓰기 권한이나 설정 파일에 문제가 있으면 앱에서 오류를 표시합니다. 이미 API가 켜진 상태에서도 같은 메뉴로 권한을 다시 요청할 수 있습니다.

음악 앱 없이 UI만 확인하려면 실행 중인 Pear Now Playing을 메뉴에서 종료한 뒤 아래 명령을 사용합니다.

```sh
open 'macos/build/Pear Now Playing.app' --args --preview
```

미리보기는 실제 음악 앱에 연결하지 않습니다. 정상 모드로 돌아가려면 종료 후 앱을 다시 실행합니다.

## 기능

- 다른 앱으로 클릭과 키 입력을 전달하는 비활성 오버레이, 여러 데스크톱 및 전체 화면 공간 참여
- 앨범 아트, 긴 제목 스크롤, 아티스트·앨범, 실시간 진행 바, 곡 변경 및 재생 상태 변화 시 표시
- LRCLIB 싱크 가사 검색, 제목·재생 길이 기반 아티스트 별칭 대응, 네트워크 실패 재시도
- 현재 가사 강조와 스크롤, 가사 타이밍 보정, 한국어·일본어 Pretendard JP 폰트
- 메뉴 막대 재생 제어, 계속 표시, 가사 표시, 위치 6개, 크기 4단계
- 만료 토큰 재인증, 연결 끊김 후 재접속, 토큰 파일 권한 `0600`

macOS의 창 관리 정책에 따라 일부 독점 전체 화면 앱에서는 오버레이가 보이지 않을 수 있습니다.

| 단축키 | 기능 |
|---|---|
| `Control + Option + ↑` | 지금 곡 다시 보기 |
| `Control + Option + ↓` | 재생 / 일시정지 |
| `Control + Option + →` | 다음 곡 |
| `Control + Option + ←` | 이전 곡 |
| `Control + Option + P` | 계속 표시 |
| `Control + Option + L` | 가사 표시 |

단축키는 Carbon 전역 단축키 API로 등록하며 접근성 권한이 필요하지 않습니다. 다른 앱이 이미 사용 중인 조합은 등록되지 않으며 Console에 기록됩니다. 이 포트에서는 단축키 조합 변경을 지원하지 않습니다.

## 원본 디자인과 위치

`src/Theme.cs`, `src/CardRenderer.cs`, `src/LyricsView.cs`의 색상과 레이아웃을 macOS 네이티브 렌더러로 옮겼습니다. 카드 배경 `#242427`, 테두리 `#33333a`, 코랄 강조 `#ff9294`, Pretendard JP, 16pt 여백·모서리, 60pt 앨범 아트와 상태·시간 헤더를 사용합니다. 가사 강조선은 현재 줄 옆에만 표시되며, 일시정지 시 회색으로 바뀝니다. macOS에서는 수치를 논리 좌표(pt)로 사용하고 Retina 배율로 렌더링합니다.

기본 위치는 왼쪽 40pt, 아래쪽 140pt 여백입니다. 가사가 있으면 가사 카드를 아래쪽 여백에 붙이고 곡 카드를 10pt 위에 배치합니다. 상단 배치에서는 곡 카드가 여백에 붙고 가사가 그 아래로 이어집니다. 계속 표시를 끄면 곡 카드만 사라지고 가사는 유지되며, 고정 높이의 빈 공간은 남기지 않습니다.

렌더링 결과를 GUI 없이 확인할 수 있습니다.

```sh
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --render-preview /tmp/pear-preview.png
```

## 설정과 데이터

메뉴의 **설정 파일 열기**로 `~/Library/Application Support/PearNowPlaying-macOS/config.json`을 엽니다. 변경 후 **설정 다시 불러오기**를 선택합니다.

| 설정 | 기본값 | 설명 |
|---|---|---|
| `host`, `port` | `127.0.0.1`, `26538` | 로컬 Pear API 주소. 호스트는 `127.0.0.1` 또는 `localhost` |
| `position` | `BottomLeft` | `TopLeft`, `TopCenter`, `TopRight`, `BottomLeft`, `BottomCenter`, `BottomRight` |
| `marginX`, `marginY` | `40`, `140` | 화면의 사용 가능한 영역으로부터 여백(pt) |
| `scale`, `panelWidth` | `1`, `420` | 배율(0.5–3), 기본 카드 너비(260–800pt) |
| `monitor` | `0` | 화면 목록의 번호, 0부터 시작 |
| `showSeconds`, `opacity` | `6`, `0.92` | 임시 표시 시간, 배경 불투명도 |
| `alwaysShow`, `showLyrics` | `false`, `true` | 계속 표시 및 싱크 가사 표시 |
| `lyricsOffsetMs` | `300` | 양수는 가사를 더 빨리 표시 |

기본 스키마의 키를 유지하세요. 파싱할 수 없거나 유효 범위를 벗어나는 설정은 기본값으로 대체됩니다. 토큰은 같은 폴더의 `token.txt`에 저장하며 Windows 설정/토큰은 가져오지 않습니다.

통신 대상은 로컬 Pear API, 곡의 HTTPS 앨범 아트 주소, `https://lrclib.net`입니다. LRCLIB 검색에는 곡 제목·아티스트·앨범·길이를 보냅니다. 포함된 Pretendard JP 폰트의 OFL은 기존 `assets/fonts/PretendardJP-OFL.txt`와 앱의 Resources에 있습니다.

## 검증

```sh
./macos/build.sh
'macos/build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying' --self-test
python3 macos/Tests/mock_pear.py
```

자체 테스트는 LRC의 다중 타임스탬프·오프셋·빈 줄·가사 위치와 플레이어 상태/탐색을 검증합니다. Python 표준 라이브러리 모의 서버는 만료 토큰의 WebSocket 거절, 재인증, 초기 곡/위치/재생 이벤트, Bearer 재생 제어, 토큰 파일 권한을 검증합니다. 외부 서비스나 로그인된 음악 계정은 필요하지 않습니다. 모의 서버 테스트에는 로컬 TCP 포트 바인딩 권한이 필요합니다.

GitHub Actions의 `macOS` 워크플로에서 빌드와 두 테스트를 실행하고 앱 ZIP을 아티팩트로 만듭니다. GUI·실제 Pear 권한 대화상자·전체 화면 배치는 Mac에서 별도로 확인해야 합니다.
