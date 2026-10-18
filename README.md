# Pear Now Playing

[Pear Desktop](https://github.com/pear-devs/pear-desktop)(YouTube Music 데스크톱 앱)에서 재생 중인 곡을 화면 위에 띄워주는 Windows 오버레이 위젯이에요.
곡이 바뀌면 화면 구석에 앨범 아트, 제목, 아티스트, 진행 바가 몇 초 동안 뜨고,
싱크 가사가 있는 곡은 YouTube Music 모바일 앱처럼 부드럽게 스크롤되는 가사 카드가 함께 떠요.

<p align="center">
  <img src="docs/lyrics-scroll.gif" alt="가사 스크롤 미리보기" width="460">
</p>

- 전체 화면 게임, 영상, 작업 화면 어디 위에든 떠요. 테두리 없는 창 모드 게임에서 쓰기 좋아요.
- 클릭과 키 입력은 아래 창으로 그대로 전달돼요. 위젯이 포커스를 가져가지 않아요.
- 전역 단축키로 이전 곡, 다음 곡, 재생/일시정지를 할 수 있어요.
- Windows 10/11에 기본으로 들어 있는 .NET Framework 4.8로 돌아가서 따로 설치할 게 없어요.

디자인은 [carol-web](https://github.com/team-carol/carol-web)의 디자인 시스템(색 토큰, Pretendard 계열 폰트, 16px 둥근 카드, 1px 테두리, 3px 강조선)을 따랐어요.

## 기능

| | |
|---|---|
| **곡 카드** | 앨범 아트, 제목, 아티스트·앨범, 진행 바. 곡이 바뀌거나 일시정지/재생할 때 잠깐 떴다가 사라져요. 계속 띄워둘 수도 있어요 |
| **싱크 가사** | YouTube Music 가사를 먼저 찾고, 없으면 [LRCLIB](https://lrclib.net)에서 찾아 곡 카드 아래에 붙여 보여줘요 |
| **긴 제목 스크롤** | 제목이 카드보다 길면 전광판처럼 옆으로 흘러가요 |
| **일본어 폰트** | 한국어·영어·일본어를 Pretendard JP 한 가지 폰트로 보여줘요 |
| **단축키** | 다시 보기, 재생/일시정지, 다음/이전 곡, 계속 표시, 가사 켜기/끄기 |

<p align="center">
  <img src="docs/title-marquee.gif" alt="긴 제목 스크롤 미리보기" width="460">
</p>

---

## macOS 네이티브 포트

macOS 13 이상에서는 Swift/AppKit으로 만든 [macOS 버전의 빌드·실행 안내](macos/README.md)를 사용하세요. 곡 정보·싱크 가사 오버레이, 메뉴 막대 제어, 전역 단축키를 제공합니다.

## 설치

### 1. Pear Desktop 설정 (처음 한 번)

1. Pear Desktop 메뉴에서 **플러그인 → API 서버 [베타]** 를 켜요.
2. (권장) 같은 메뉴의 **호스트 명**을 `0.0.0.0`에서 `127.0.0.1`로 바꿔요.
   `0.0.0.0`이면 같은 네트워크의 다른 기기에서도 API 서버에 접속을 시도할 수 있어요.
3. **포트**는 기본값 `26538` 그대로 두면 돼요. 바꿨다면 위젯 설정 파일의 `port`도 똑같이 맞춰요.
4. **인증 정책**은 기본값(첫 번째 요청 시 인증) 그대로 두면 돼요.

### 2. 실행

1. [Releases](../../releases)에서 zip을 받아 압축을 풀고 `PearNowPlaying.exe`를 실행해요.
   작업 표시줄 오른쪽 트레이에 음표 아이콘이 생겨요.
2. Pear Desktop에 **"pear-now-playing ... API에 액세스하도록 허용하시겠습니까?"** 창이 뜨면 **허용**을 눌러요. 처음 한 번만 물어봐요.
3. 노래를 틀면 화면 왼쪽 아래에 곡 정보가 떠요.

> 서명되지 않은 프로그램이라 처음 실행할 때 "Windows의 PC 보호" 창이 뜰 수 있어요. **추가 정보 → 실행**을 누르면 돼요.

Windows를 켤 때 자동으로 실행하려면 `Win + R` → `shell:startup` 폴더에 exe 바로가기를 넣으면 돼요.

## 단축키

| 단축키 | 기능 |
|---|---|
| `Ctrl + Alt + ↑` | 지금 곡 다시 보기 |
| `Ctrl + Alt + ↓` | 재생 / 일시정지 |
| `Ctrl + Alt + →` | 다음 곡 |
| `Ctrl + Alt + ←` | 이전 곡 |
| `Ctrl + Alt + P` | 곡 정보 계속 표시 켜기/끄기 |
| `Ctrl + Alt + L` | 가사 표시 켜기/끄기 |

다른 앱을 쓰는 중에도 동작해요. 다른 키로 바꾸고 싶으면 설정 파일에서 고치면 돼요.

## 가사

- 곡이 바뀌면 싱크 가사를 두 곳에서 찾아요. 둘 다 Pear Desktop의 가사 플러그인이 쓰는 곳이에요.
  1. **YouTube Music**: YouTube Music 앱에 나오는 그 가사예요. Pear의 YTMusic 가사 제공자와 같은 방식으로 가져와요(아래 참고).
  2. **[LRCLIB](https://lrclib.net)**: 1에서 못 찾았거나 실패하면 이 공개 가사 DB에서 찾아요. 매칭 방식도 Pear와 같아요.
- **커버곡(歌ってみた 등)**: 개인이 올린 영상이라 YouTube Music 가사가 없으면, 영상 설명란에 있는 원곡 링크를 찾아
  **원곡의 싱크 가사**를 대신 보여줘요. 歌ってみた는 보통 원곡 반주를 그대로 써서 타이밍이 잘 맞아요.
  - "原曲 / 本家 / original / 원곡" 같은 말이 붙은 링크를 먼저 보고, Mix·Off Vocal·일러스트 링크는 건너뛰어요.
  - 제목에 remix, arrange, アレンジ, 편곡, acoustic, 弾き語り, piano ver, short ver 같은 말이 있으면 음악이 바뀐 거라 쓰지 않아요.
  - 원곡과 커버의 길이가 10초 넘게 다르면(인트로를 자르거나 편곡한 경우) 쓰지 않아요.
  - 설명란에 원곡 링크가 없으면 제목에서 곡 이름과 원곡자를 읽어서(예: `ワールドイズマイン / ryo(covered by …)` → "ワールドイズマイン", "ryo")
    LRCLIB에서 원곡을 찾아요. 제목에 원곡자가 없으면 설명란의 "原曲：…", "作詞・作曲：…", "Music: …" 줄을 봐요.
    원곡자를 모르면 곡 이름이 같고 길이가 10초 안으로 비슷한 곡을 골라요.
    (YouTube Music 검색은 로그인하지 않으면 공식 음원이 나오지 않아서 쓰지 않아요.)
  - 원곡에 YouTube Music 가사가 없으면 원곡 제목·아티스트로 LRCLIB에서 찾아요.
    트레이 가사 상태에 "(YouTube Music · 원곡)", "(LRCLIB · 원곡 검색)"처럼 표시돼요.
- 곡을 듣는 중에 Pear 재생목록의 **다음 곡 가사를 미리 찾아둬요**(곡이 시작되고 10초 뒤). 다음 곡이 시작되면 가사가 바로 떠요.
  미리 찾을 때 못 찾은 곡은 그 곡이 시작될 때 다시 찾아요.
- YouTube Music 가사 중계 서버가 3번 연달아 실패하면 10분 동안은 LRCLIB에서만 찾아요. **가사 다시 찾기**를 누르면 바로 다시 시도해요.
- 아티스트 표기가 달라도(`Mikito-P`와 `みきとP`처럼) 제목이 같고 곡 길이가 3초 안으로 같으면 같은 곡으로 봐요.
- LRCLIB는 무료로 운영되는 서버라 사람이 몰리면 잠깐씩 "바쁨"(503) 응답을 줘요. 그러면 2초 뒤 한 번 더 물어보고,
  그래도 안 되면 15초, 45초 뒤에 처음부터 다시 찾아봐요. 그래도 안 되면 트레이 메뉴의 **가사 다시 찾기**를 누르면 돼요.
  다시 찾는 동안과 결과가 화면에 잠깐 떠요.
- 찾으면 **곡 카드 바로 아래**에 가사 카드가 붙어서 계속 표시돼요. 두 카드는 너비가 같아서 한 덩어리처럼 보여요.
- 이전 줄·지금 줄·다음 줄이 한 목록으로 보이고, 줄이 바뀌면 목록이 부드럽게 위로 스크롤돼요.
  지금 줄은 밝게, 나머지는 흐리게 보이고, 위아래 끝으로 갈수록 자연스럽게 사라져요. 긴 줄은 두 줄까지 넘어가요.
- 곡 카드가 나타나거나 사라지면 가사 카드도 미끄러지듯 자리를 옮겨요.
- 간주 구간에는 ♪가 떠요. 일시정지하면 강조선이 회색으로 바뀌어요.
- 싱크 가사가 없는 곡(가사 DB에 없거나 타이밍 없는 가사만 있는 곡)은 가사 카드를 띄우지 않아요. 트레이 메뉴 맨 위에서 가사 상태를 볼 수 있어요.
- 가사가 노래보다 빠르거나 늦으면 트레이 메뉴의 **가사 타이밍**에서 맞추면 돼요.

> 영상 자막(YouTube 자막)을 가져오는 기능은 넣지 않았어요. 공식 방법 없이 YouTube 내부 데이터를 긁어와야 해서 YouTube 약관에 어긋나요.

## 긴 곡 제목

제목이 카드 너비보다 길면 1.8초 동안 앞부분을 보여준 뒤 옆으로 천천히 흘러가요.
끝까지 가면 제목 앞부분이 이어서 들어오면서 계속 반복되고, 양쪽 끝은 부드럽게 흐려져요.
제목이 카드에 다 들어가면 움직이지 않아요. 아티스트·앨범 줄은 `…`로 줄여서 보여줘요.

## 폰트

한국어, 영어, 일본어(가나와 상용 한자 약 7,100자) 모두 **Pretendard JP** 한 가지 폰트로 보여줘요.
폰트에 없는 글자(희귀 한자, 중국어 간체 등)가 섞인 줄만 Windows 폰트(Yu Gothic, 맑은 고딕)로 바뀌어요.

## 트레이 메뉴

트레이 아이콘을 우클릭하면 나와요. 아이콘을 더블클릭하면 지금 곡이 떠요.

- **곡 정보 계속 표시**: 곡 카드가 사라지지 않고 계속 떠 있게 해요. 진행 바가 실시간으로 움직여요.
- **가사 표시 / 가사 다시 찾기 / 가사 타이밍**: 가사 카드 켜기/끄기, 지금 곡 가사 다시 검색, 1초 빠르게 ~ 1초 늦게
- **YouTube Music 가사 먼저 찾기**: 끄면 LRCLIB에서만 찾아요.
- **위치**: 6곳 중에서 골라요. 기본은 왼쪽 아래예요.
- **크기**: 작게 / 보통 / 크게 / 아주 크게
- **이전 곡 / 재생·일시정지 / 다음 곡**
- **Pear 연결 권한 다시 요청**: 허용 창에서 실수로 거부했을 때 눌러요.
- **설정 파일 열기 / 설정 다시 불러오기 / 오류 기록 열기**

## 설정 파일

`%AppData%\PearNowPlaying\config.ini` 에 있어요. 트레이 메뉴의 **설정 파일 열기**로 바로 열 수 있고,
고친 뒤 **설정 다시 불러오기**를 누르면 적용돼요.

| 항목 | 기본값 | 설명 |
|---|---|---|
| `host`, `port` | `127.0.0.1`, `26538` | Pear Desktop API 서버 주소 |
| `position` | `BottomLeft` | `TopLeft`, `TopCenter`, `TopRight`, `BottomLeft`, `BottomCenter`, `BottomRight` |
| `marginX`, `marginY` | `40`, `140` | 화면 가장자리로부터의 여백(px). 다른 UI와 겹치면 조절해요 |
| `scale` | `1.0` | 크기 배율 |
| `panelWidth` | `420` | 곡 카드와 가사 카드의 너비(px) |
| `monitor` | `0` | 표시할 모니터 번호 (0 = 주 모니터) |
| `showSeconds` | `6` | 곡이 바뀌었을 때 표시하는 시간(초) |
| `opacity` | `0.92` | 배경 불투명도 |
| `alwaysShow` | `false` | 계속 표시 |
| `showOnPause` | `true` | 일시정지/재생할 때도 잠깐 표시 |
| `showAlbumArt` | `true` | 앨범 아트 표시 |
| `showLyrics` | `true` | 가사 카드 표시 |
| `lyricsOffsetMs` | `300` | 가사 타이밍 보정(ms). +면 빨리, -면 늦게 |
| `lyricsServer` | `https://lrclib.net` | LRCLIB 주소 |
| `ytmLyrics` | `true` | YouTube Music 가사를 먼저 찾기. `false`면 LRCLIB만 |
| `ytmLyricsProxy` | `https://ytmbrowseproxy.zvz.be/` | YouTube Music 가사 중계 서버 |
| `hotkey...` | 위 표 참고 | 비워두면 그 단축키는 꺼져요 |

## 문제 해결

- **게임 위에 안 보여요**: 독점 전체 화면 모드는 다른 창이 위에 못 뜨게 하는 경우가 있어요.
  게임 설정에서 **테두리 없는 창 모드**(borderless / 전체 창 모드)로 바꿔보세요.
- **트레이 상태가 "Pear Desktop 기다리는 중"이에요**: Pear Desktop이 꺼져 있거나 API 서버 플러그인이 꺼져 있어요.
  포트를 바꿨다면 설정 파일의 `port`도 맞춰주세요.
- **"단축키를 등록하지 못했어요" 알림이 떠요**: 다른 프로그램이 같은 단축키를 쓰고 있어요. 설정 파일에서 다른 키로 바꿔주세요.
- **가사가 안 떠요**: 트레이 메뉴 맨 위 가사 상태를 보세요.
  - '찾지 못함': YouTube Music과 LRCLIB 둘 다 그 곡의 싱크 가사가 없거나, 제목·아티스트·길이가 가사 DB와 너무 달라요. MV 버전은 길이가 달라서 못 찾는 경우가 많아요.
  - '가사 서버에 연결하지 못함': 가사 서버가 느리거나 잠깐 안 되는 상태예요. 잠시 뒤 트레이 메뉴의 **가사 다시 찾기**를 눌러주세요.
  - `error.log`에 곡마다 가사를 어떻게 찾았는지(또는 못 찾았는지) 한 줄씩 남아요.
- **그 밖의 문제**: 트레이 메뉴 **오류 기록 열기**로 `error.log`를 확인해 주세요.

## 통신하는 곳

- 내 컴퓨터의 Pear Desktop API 서버(`127.0.0.1:26538`)
- 앨범 아트 이미지 주소 (YouTube Music이 쓰는 Google 이미지 서버)
- YouTube Music 가사 (`ytmLyrics=true`일 때):
  - `music.youtube.com`: 지금 곡의 영상 ID를 보내 가사 ID를 받아요.
  - `ytmbrowseproxy.zvz.be`: 가사 ID를 보내 가사를 받아요(로그인 없이 YouTube Music에 직접 요청하면 가사가 오지 않아요).
    공식 음원은 시간 맞춘 가사가 오는 경우가 많고, MV·업로드 영상은 대부분 오지 않아요.
  - 그래서 MV를 들을 때는 YouTube Music의 아티스트 페이지에서 같은 제목의 싱글/앨범을 찾아,
    길이가 같은 **공식 음원**의 가사를 대신 받아요. 커버의 원곡 링크가 MV일 때도 똑같이 해요.
    Pear Desktop의 YTMusic 가사 제공자가 쓰는 **외부 중계 서버**예요(Google 공식 서버 아님).
  - 가사 요청은 YouTube Music 앱(클라이언트 이름 26, 버전 7.01.05)으로 보내요.
  - `www.youtube.com`: 개인 업로드 영상(커버 등)에서 가사를 못 찾았을 때만, 원곡 링크를 찾으려고 그 영상의 설명란을 읽어요.
  - 어느 곳에도 Google 계정 쿠키나 Pear 연결 토큰은 보내지 않아요.
  - 공식 API가 아니라서 YouTube나 중계 서버 쪽 사정으로 언제든 막힐 수 있어요. 그러면 자동으로 LRCLIB만 써요.
- 가사 검색: `lrclib.net` (곡 제목, 아티스트, 앨범 이름, 길이만 보내요)

그 밖에는 인터넷에 접속하지 않아요. 연결 토큰은 `%AppData%\PearNowPlaying\token.txt`에 저장돼요.

## 빌드

C# 7.3, .NET Framework 4.8, WinForms로 만들었어요. 외부 패키지는 쓰지 않아요.

| 파일 | 내용 |
|---|---|
| `src/PearClient.cs` | Pear API 서버 인증(`POST /auth/{id}`), WebSocket(`/api/v1/ws`) 수신, 재생 제어 |
| `src/OverlayWindow.cs` | 클릭이 통과하는 항상 위 창 (`UpdateLayeredWindow`), 페이드와 이동 애니메이션 |
| `src/CardRenderer.cs` | 곡 카드 그리기, 긴 제목 스크롤 |
| `src/LyricsView.cs` | 스크롤되는 가사 목록과 전환 애니메이션 |
| `src/Lyrics.cs` | 가사 찾는 순서, LRCLIB 검색(Pear와 같은 매칭 방식), LRC 파서 |
| `src/YtmLyrics.cs` | YouTube Music 가사 (Pear의 YTMusic 가사 제공자와 같은 방식), 영상 설명란 읽기 |
| `src/CoverLyrics.cs` | 커버곡 설명란에서 원곡 링크 고르기, 편곡·리믹스 걸러내기 |
| `src/Theme.cs` | carol-web 색 토큰, Pretendard JP 로딩과 글리프 커버리지 확인 |
| `src/TrayApp.cs`, `src/Hotkeys.cs`, `src/Config.cs` | 트레이 메뉴, 전역 단축키, 설정 |

- **Windows**: [.NET SDK](https://dotnet.microsoft.com/download)를 깔고 `dotnet build -c Release` 하면 돼요. Visual Studio에서 `PearNowPlaying.csproj`를 열어도 돼요.
- **Linux**: `build.sh`가 dotnet SDK의 Roslyn 컴파일러와 Mono의 .NET Framework 참조 어셈블리로 `bin/PearNowPlaying.exe`를 만들어요.

## 라이선스 참고

Pretendard JP 폰트(Regular, Medium)를 exe 안에 포함했어요. SIL Open Font License 1.1로 배포되는 폰트이고,
라이선스 전문은 [`assets/fonts/PretendardJP-OFL.txt`](assets/fonts/PretendardJP-OFL.txt)에 있어요.
Copyright (c) 2021, Kil Hyung-jin (https://github.com/orioncactus/pretendard), with Reserved Font Name Pretendard JP.

YouTube Music, Pear Desktop과는 관계없는 개인 프로젝트예요.
