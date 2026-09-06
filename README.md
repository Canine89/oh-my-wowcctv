# Oh My WoW CCTV

WoW 쐐기 던전을 **자동으로 녹화**해 주는 macOS 메뉴바 앱입니다. OBS 를 엔진으로 쓰지만, 사용자는 OBS 를 만질 필요가 없습니다.

- WoW 가 켜지면 감지하고, **CCTV 전용 프로필/장면으로 OBS 를 몰래 띄웁니다** (창 숨김).
- 쐐기돌을 넣고 타이머가 돌기 시작하면 녹화를 시작합니다.
- 마지막 우두머리를 잡거나(또는 포기하거나) 던전을 나오면 몇 초 뒤 녹화를 멈춥니다.
- 녹화 파일 이름에 `던전 +단수 완료 28분31초` 를 붙여 줍니다.
- WoW 가 꺼지면 OBS 를 종료하고, 사용자가 원래 쓰던 OBS 프로필/장면으로 되돌려 놓습니다.

## 동작 원리

```
WoW ──(애드온이 /combatlog 자동 ON)──▶ Logs/WoWCombatLog-*.txt
                                          │  CHALLENGE_MODE_START / CHALLENGE_MODE_END
                                          ▼
                              Oh My WoW CCTV (메뉴바 앱, 파일 tail)
                                          │  OBS 를 --profile/--collection OhMyWowCCTV 로 숨겨서 실행
                                          │  내부 제어 채널: obs-websocket (StartRecord / StopRecord)
                                          ▼
                                   OBS (CCTV 전용 프로필)
```

CCTV 전용 프로필은 처음 한 번 사용자의 현재 OBS 프로필을 복제해 만들고(방송 계정 정보는 제외), 녹화 경로·파일명·하드웨어 H.264 고화질만 덮어씁니다.
장면 모음은 `WoW 창 캡처(ScreenCaptureKit) + WoW 앱 소리 + 마이크` 로 자동 생성됩니다. OBS 창을 열어 세부 조정을 해도 CCTV 프로필에 그대로 남습니다.

WoW 애드온은 파일을 직접 쓸 수 없으므로, 동봉된 `OhMyWowCCTV` 애드온은 **던전/공격대에 입장하면 전투 기록을 켜는 일**만 합니다.
그러면 클라이언트가 `CHALLENGE_MODE_START`, `CHALLENGE_MODE_END`, `ENCOUNTER_*` 줄을 로그 파일에 남기고, 앱이 그것을 읽어 OBS 를 제어합니다.

## 요구 사항

- macOS 14 이상
- OBS 28 이상 (obs-websocket 5 내장)
- World of Warcraft 리테일 (`/Applications/World of Warcraft/_retail_`)

## 설치

```bash
make install     # 빌드 후 /Applications/OhMyWowCCTV.app 으로 복사하고 실행
make addon       # 애드온을 WoW Interface/AddOns 에 복사 (앱 설정 창의 버튼으로도 가능)
```

처음 한 번만 할 일:

1. **애드온 설치** — 앱 메뉴 `설정… → WoW → 애드온 설치`. WoW 안에서 `/reload`.
2. (선택) 설정에서 **로그인 시 자동 실행** 켜기.
3. (선택) 설정에서 녹화 폴더·캡처 대상·마이크 여부 조정.

OBS 웹소켓 서버, 전용 프로필, 장면 모음은 앱이 첫 실행 때 알아서 준비합니다. macOS 가 OBS 에 화면 기록/마이크 권한을 묻는다면 허용하세요.

## 사용

그냥 켜 두면 됩니다. 메뉴바 아이콘이 상태를 보여 줍니다.

| 아이콘 | 상태 |
|---|---|
| 카메라(빗금) | WoW 대기 중 |
| 카메라 | WoW 실행 중, 쐐기 대기 |
| 빨간 점 | 녹화 중 |
| 주황 점 | 쐐기 종료, 곧 녹화 정지 |

**CCTV 모니터 (메뉴 → CCTV 모니터 열기, ⌘M)**

OBS 가 실제로 렌더링하는 화면을 그대로 실시간 미리보기(기본 30fps, 설정에서 15/30/60)로 보여 줍니다. 미리보기는 창이 열려 있을 때만 받아오므로 평소에는 CPU 를 거의 쓰지 않습니다. 그 아래에서 소스 켜고 끄기, 오디오 미터·볼륨·음소거, 캡처 대상(WoW 창 / 주 디스플레이) 즉시 전환, 녹화 시작/정지, 녹화 테스트를 할 수 있습니다. 인코더 같은 세부 설정은 "OBS 창 열기"로 OBS 를 직접 엽니다.

WoW 가 **독점 전체 화면**이면 게임이 창을 거치지 않고 화면에 직접 그리기 때문에 창 캡처가 비어 있습니다. 앱은 WoW 창이 디스플레이 크기와 같으면 자동으로 그 디스플레이를 캡처합니다(게임이 앞에 있을 때 게임이 잡힘). 미리보기를 보면서 확인하고 싶으면 WoW 그래픽 설정에서 **창 모드(전체 화면)** 을 권장합니다.

"WoW 창" 모드는 WoW 를 응용 프로그램 캡처(번들 ID 기반)로 잡고, 앱이 추적하는 WoW 창의 위치·크기만큼 프레임을 잘라내 녹화 해상도를 창의 실제 픽셀 크기에 맞춥니다. 창 ID 에 의존하지 않아 WoW 를 다시 켜도 안정적이고, 창을 옮기거나 크기를 바꿔도 따라갑니다. 창 모드일 때 macOS 제목 표시줄은 잘라냅니다(설정에서 끌 수 있음). 검은 띠 없이 창 내용만 1:1 로 녹화되고, 미리보기도 같은 비율로 보입니다. 창 크기를 바꾸거나 다른 모니터로 옮기면 자동으로 다시 맞춥니다(녹화 중에는 해상도를 바꾸지 않음).

마이크는 사용자가 원래 OBS 에서 쓰던 장치를 그대로 가져오고, CCTV 모니터의 믹서 카드에서 장치를 바꿀 수 있습니다.

**쐐기 전에 녹화 테스트하기**

- 게임을 켠 뒤 **⌃⌥⌘R** 을 누르면 바로 녹화가 시작되고('팝' 소리), 다시 누르면 멈춥니다('병' 소리). 전체화면 게임 중에도 동작합니다.
- 메뉴바 → **녹화 테스트** 를 누르면 15초 녹화 후 파일을 Finder 에서 열어 줍니다. 길이는 설정에서 바꿀 수 있습니다.
- 녹화가 시작되지 않으면 '경고음'이 나고 이벤트 로그에 이유가 남습니다.

게임 안 명령:

```
/cctv           상태 보기
/cctv on|off    자동 전투 기록 켜기/끄기
/cctv raid      공격대에서도 기록할지 토글
/cctv quiet     채팅 안내 숨기기
```

## 개발

```bash
make gen    # xcodegen 으로 Xcode 프로젝트 생성
make open   # Xcode 에서 열기
make test   # 단위 테스트
make run    # Release 빌드 후 dist/ 에서 실행
```

구조:

```
Addon/OhMyWowCCTV/          WoW 애드온 (앱 번들 Resources/Addon 에 동봉됨)
Sources/OhMyWowCCTV/
  App.swift                 메뉴바 앱 진입점
  RecordingCoordinator.swift 상태 머신: WoW ↔ 전투 로그 ↔ OBS
  CombatLogWatcher.swift    Logs 폴더에서 최신 WoWCombatLog*.txt tail
  CombatLogParser.swift     CHALLENGE_MODE_* / ENCOUNTER_* / ZONE_CHANGE 파싱
  OBSManager.swift          OBS 래퍼: 숨김 실행, 프로필 전환, 종료 후 원복
  OBSConfigFiles.swift      INI 편집기, CCTV 프로필/장면 모음 생성, 웹소켓 설정
  OBSClient.swift           obs-websocket 5 클라이언트 (내부 제어 채널)
  ProcessMonitor.swift      WoW / OBS 실행 감지
  AddonInstaller.swift      동봉 애드온을 Interface/AddOns 에 복사
  Views/                    메뉴, 설정, 이벤트 로그
Tests/                      파서 / 감시기 테스트
```

## 문제가 생기면

- 메뉴 → **이벤트 로그…** 에서 무슨 일이 있었는지 볼 수 있고, 같은 내용이 `~/Library/Logs/OhMyWowCCTV.log` 에도 남습니다.
- 미리보기가 검게 나오면 CCTV 모니터의 **캡처 다시 잡기** 를 눌러 보세요. 앱은 WoW 창이 뜬 것을 확인한 뒤 캡처 대상을 자동으로 다시 잡고, 창 크기나 디스플레이가 바뀌어도 다시 적용합니다.
- 그래도 검으면 macOS 가 OBS 에 화면 기록 권한을 주지 않은 것입니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 기록에서 OBS 를 허용하세요.

## 알아둘 점

- 전투 로그 파일 쓰기 지연 때문에 녹화는 쐐기 시작 후 약 0.5~1초 뒤부터 시작됩니다. 10초 카운트다운 안쪽이라 실제 플레이는 빠지지 않습니다.
- 던전을 나가도 쐐기 인스턴스는 유지되므로, 애드온은 나간 뒤 3분 동안 전투 기록을 유지하고 앱은 기본 30초(설정 가능) 안에 돌아오지 않을 때만 녹화를 멈춥니다. 돌아오면 같은 녹화를 이어갑니다.
- 녹화 중 WoW 가 종료되면 녹화를 멈춘 뒤 OBS 를 종료합니다.
- WoW 를 켤 때 OBS 가 이미 실행 중이면 그 OBS 에 붙어 CCTV 프로필로 전환하고, WoW 가 꺼지면 원래 프로필로 되돌립니다. 방송 중이면 전환하지 않고 현재 장면을 그대로 녹화합니다.
- OBS 창을 보고 싶으면 메뉴의 "OBS 창 보기"를 누르세요.
