Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | **한국어** | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine은 Wallpaper Engine 배경화면(장면, 동영상, 웹)을 재생하고 편집하는 무료 오픈 소스 macOS 앱입니다. 장면은 네이티브 Metal 렌더러로 그려지며 효과, 파티클, 3D 모델, 조명, SceneScript, 오디오 반응형 비주얼을 지원하고, Steam 창작마당이 내장되어 있습니다. Haren Chen과 MrWindDog의 [Open Wallpaper Engine](https://github.com/MrWindDog) 포크로 시작했으며, 이후 대부분 새로 작성되었습니다.

> **참고:** 이 프로젝트는 Steam의 상용 Wallpaper Engine과 관련이 없습니다. Wallpaper Engine의 Steam 창작마당에 있는 배경화면 에셋을 표시할 수 있는 오픈 소스 macOS 앱입니다. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**웹사이트:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **위키:** [가이드 및 문제 해결](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![보관함](../../docs/images/library.jpg)

## 차별점

- **Wallpaper Engine 장면을 편집하는 유일한 macOS 앱.** 배경화면 편집기는 장면의 레이어, 효과, 파티클, 타임라인, 스크립트를 열고 Wallpaper Engine 배경화면으로 저장합니다.
- **Live Photo 및 Wallpaper Engine Android 내보내기.** 어떤 장면이나 동영상이든 iPhone 및 iPad용 움직이는 잠금 화면 또는 Wallpaper Engine Android 앱용 패키지가 됩니다.
- **Wallpaper Engine 자체 셰이더를 변환.** 모든 레이어, 효과, 머티리얼은 배경화면의 원본 셰이더를 Metal로 변환해 그려지며, 창작마당 제작자가 직접 작성한 효과도 포함됩니다.
- **완전히 실시간으로 동작하는 화면 보호기.** 화면 보호기는 각 디스플레이의 배경화면을 실행하면서 그리므로 시계, 스크립트, 오디오 반응형 요소가 계속 움직입니다. 아무것도 녹화하지 않습니다.

## 주요 기능

- **장면, 동영상, 웹 배경화면**: 장면은 효과, 파티클, 3D 모델, 조명, 타임라인, SceneScript, 오디오 반응형 비주얼을 지원하며, 이를 표시할 수 있는 디스플레이에서는 장면과 HDR10 또는 HLG 동영상을 HDR로 출력합니다. 웹 배경화면은 WebKit 또는 선택 사항인 Chromium 엔진에서 실행되며, 폴더 속성, 실시간 오디오, Now Playing을 지원합니다.
- **Steam 창작마당**: Wallpaper Engine의 정렬 및 필터로 둘러보고, 사용자 본인의 Steam 계정으로 SteamCMD를 통해 다운로드하거나, 배경화면 폴더와 zip 파일을 가져올 수 있습니다. 설치됨 탭에는 Wallpaper Engine의 폴더와 정렬이 있습니다.
- **배경화면 편집기**: Wallpaper Engine 편집기를 본뜬 편집기입니다. 기즈모로 레이어를 추가하고 배치하며, 미리보기와 함께 효과를 추가하고, 셰이더 편집기에서 자신만의 효과를 작성하고 편집하며, FBX 및 OBJ 모델을 가져오고, 타임라인에서 애니메이션을 만들고, SceneScript를 작성하고, 사용자 속성을 만들고, 파티클 시스템과 Puppet Warp 리그를 편집하고, Wallpaper Engine의 이미지 도구(전경 분리, 캐릭터 시트 생성, 법선 맵 생성)를 사용할 수 있습니다. **새 배경화면…**은 이미지 또는 Wallpaper Engine 템플릿 중 하나로 새 배경화면을 시작합니다. 편집은 초안에서 이루어지며, **저장**하면 적용되고 **새 배경화면으로 저장**하면 보관함에 사본이 추가됩니다. 배경화면 자체의 파일은 절대 변경되지 않습니다.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![배경화면 편집기](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **장면 편집/내보내기**: 실행 중인 배경화면의 레이어와 효과를 데스크탑에서 실시간으로 바꾸고, 화면 보호기에 표시할 내용을 선택하거나, 배경화면을 Live Photo 또는 Android 패키지로 내보낼 수 있습니다.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![장면 편집/내보내기](../../docs/images/scene-editor-live.jpg)

- **화면 보호기 및 잠금 화면**: 화면 보호기는 각 디스플레이의 배경화면을 실시간으로 보여 주거나(*화면 보호기를 배경화면과 동일하게*) 사용자가 선택한 배경화면을 보여 주며, 잠금 화면에는 그 이미지가 표시됩니다.

  <!-- demo: screen-saver -->

- **내보내기**: iPhone 및 iPad용 Live Photo 잠금 화면을 AirDrop으로 보내거나 사진 앱에 저장하고, Wallpaper Engine Android 패키지를 QR 코드로 Wi-Fi를 통해 기기에 보낼 수 있습니다.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Wi-Fi로 보내기](../../docs/images/send-over-wifi.png)

- **디스플레이**: Wallpaper Engine처럼 디스플레이마다 다른 배경화면, 여러 디스플레이에 걸쳐 늘리거나 각 디스플레이에 복제한 배경화면, 그룹, 분할, 프로필을 지원합니다. **윈도우에서 재생**은 배경화면을 별도의 윈도우에서 재생합니다.

  ![디스플레이](../../docs/images/displays.png)

- **플레이리스트**: 타이머, 로그인 시, 시간대, 요일에 따라 Wallpaper Engine의 전환 효과와 함께 배경화면을 바꿉니다.

  ![플레이리스트 설정](../../docs/images/playlists.png)

- **제어**: 동작, 플레이리스트, 배경화면, 디스플레이 프로필용 단축키, Wallpaper Engine의 `-control` [명령줄](../../docs/command-line.md), 그리고 **MCP 서버** 플러그인을 제공합니다. MCP 클라이언트는 이 플러그인을 통해 사용자 본인의 계정만 열 수 있는 로컬 연결로 배경화면, 플레이리스트, 설정을 지정하고 장면을 편집합니다.

  ![MCP 서버 플러그인](../../docs/images/mcp-plugin.png)

- **전원**: 화면이 잠겨 있는 동안 배경화면이 일시 정지되고, Wallpaper Engine의 *노트북 배터리 사용 시* 규칙을 따르며, 배터리 또는 저전력 모드에서는 더 낮은 품질 프리셋과 프레임 속도로 낮출 수 있습니다.
- **테마**: 메뉴 막대, 강조 색상, 색이 입혀진 아이콘과 폴더가 배경화면의 색상을 따라갑니다. Open Wallpaper Engine 자체의 윈도우에는 배경화면의 정확한 색상을 사용할 수 있습니다.

  ![테마](../../docs/images/theming.png)

그 밖의 모든 기능은 영역별로 [docs/features.md](../../docs/features.md)에서 확인하세요.

## 설치

1. [openwallpaperengine.app](https://openwallpaperengine.app/) 또는 [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases)에서 최신 릴리스를 다운로드합니다. 서명 및 공증을 거쳤으며 자동으로 업데이트됩니다.
2. DMG를 열고 **Open Wallpaper Engine**을 응용 프로그램 폴더로 드래그합니다.

**macOS 14.0(Sonoma) 이상**이 필요합니다. 장면 배경화면에는 사용자가 Steam에서 보유한 Wallpaper Engine의 Wallpaper Engine 에셋이 필요하며, 동영상 및 웹 배경화면에는 필요하지 않습니다. 일부 기능에는 더 최신 macOS, 권한 또는 플러그인이 필요합니다. [시작하기](../../docs/getting-started.md#requirements)를 참고하세요.

## 빠른 시작

1. 앱을 엽니다. 설정 도우미에서 언어, SteamCMD, Steam 로그인, Wallpaper Engine 에셋을 설정하고 Wallpaper Engine 즐겨찾기와 폴더를 가져올 수도 있습니다. 모든 단계는 건너뛸 수 있습니다.
2. 장면 배경화면을 사용하려면 Wallpaper Engine 에셋을 설치합니다(*설정 › 에셋*). 에셋은 사용자가 Steam에서 보유한 Wallpaper Engine에서 가져오며, 동영상 및 웹 배경화면은 에셋 없이도 작동합니다.
3. **발견** 및 **창작마당** 탭에서 배경화면을 찾거나, 배경화면 폴더 또는 zip 파일을 가져오거나(*파일 › 폴더에서 배경화면 가져오기…*, ⌘I), **배경화면 추가 › 새 배경화면…**으로 직접 만듭니다.
4. 보관함에서 배경화면을 클릭한 다음, 세부사항에서 **배경화면 설정**을 클릭합니다(또는 배경화면을 오른쪽 클릭하고 **배경화면으로 설정**을 선택합니다). 그 아래에 배경화면의 속성이 표시됩니다.

자세한 내용: [시작하기](../../docs/getting-started.md) 및 [위키](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## 개인정보 보호

앱이 저장하는 모든 것은 사용자의 Mac에 남으며, 어떤 데이터나 분석 정보도 수집하지 않습니다. 앱은 Steam(창작마당 및 에셋용), openwallpaperengine.app(업데이트 확인용), GitHub(업데이트 다운로드용)에 연결하며, 플러그인은 사용자가 설치할 때만 다운로드됩니다. 자세한 내용: [앱이 연결하는 대상](../../docs/getting-started.md#what-the-app-connects-to) 및 [개인정보 처리방침](../../docs/legal/privacy-policy.md).

## 문서

- [시작하기](../../docs/getting-started.md) — 요구 사항, 에셋, 창작마당, 가져오기
- [기능](../../docs/features.md) — 앱이 지원하는 모든 기능과 사용 방법
- 가이드: [디스플레이 레이아웃](../../docs/display-layouts.md) · [플레이리스트](../../docs/playlists.md) · [화면 보호기](../../docs/screen-saver.md) · [iPhone 및 iPad 내보내기](../../docs/iphone-ipad-export.md) · [Android 내보내기](../../docs/android-export.md) · [깊이 맵](../../docs/depth-maps.md) · [테마](../../docs/theming.md) · [모델 가져오기](../../docs/model-import.md) · [이미지 도구](../../docs/image-tools.md) · [MCP 서버](../../docs/mcp.md) · [명령줄](../../docs/command-line.md) · [Chromium 웹 엔진](../../docs/chromium-engine.md)
- [개발](../../docs/development.md) — 소스에서 빌드하기와 프로젝트 구조, [CONTRIBUTING.md](../../CONTRIBUTING.md) 및 [아키텍처](../../docs/architecture.md)
- [위키](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — 가이드, 설정 레퍼런스, 문제 해결

## 관련 프로젝트

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)용 PyQt6 GUI로, Steam 창작마당 연동 기능과 UI 디자인을 이 macOS 버전에서 이식했습니다.

## 크레딧

이 프로젝트는 다음 기여자들의 작업을 기반으로 합니다.

- **[MrWindDog](https://github.com/MrWindDog)** — 업스트림 [wallpaper-engine-mac](https://github.com/MrWindDog) 포크의 메인테이너로, 새로운 기능과 UI 개선 사항을 추가
- **[Haren Chen](https://github.com/haren724)** — [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac)의 최초 제작자로, 앱의 핵심 아키텍처(SwiftUI, 비디오 배경화면 재생, 가져오기 시스템, 플레이리스트 UI)를 구축
- **1ris_W** — 중국어 i18n 번역
- **[Klaus Zhu](https://github.com/klauszhu1105)** — 원래 로고 디자인
- **[Chen Chia Yang](https://github.com/Unayung)** — 장면 배경화면 렌더링, 웹 배경화면 수정, Steam 창작마당 연동, 다중 디스플레이 지원, zip 가져오기
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Metal 장면 렌더러와 효과 파이프라인, GLSL→MSL 셰이더 변환 및 캐싱, SceneScript 런타임, 오디오 응답 렌더링, 창작마당/다운로드 전면 개편, 배치 및 성능 설정, 로고 리디자인

원본 프로젝트와 동일하게 [GPL-3.0](../../LICENSE) 라이선스가 적용됩니다.

## 법적 고지

[이용 약관](../../docs/legal/terms-of-use.md) · [개인정보 처리방침](../../docs/legal/privacy-policy.md) · [보안 정책](../../SECURITY.md)

- **English:** Please read the Terms of Use and the Privacy Policy.
- **Deutsch:** Bitte lesen Sie die Nutzungsbedingungen und die Datenschutzrichtlinie.
- **Français :** Veuillez lire les conditions d’utilisation et la politique de confidentialité.
- **Español:** Lee las condiciones de uso y la política de privacidad.
- **Português (Brasil):** Leia os Termos de Uso e a Política de Privacidade.
- **Italiano:** Leggi le condizioni d’uso e l’informativa sulla privacy.
- **日本語：** 利用規約とプライバシーポリシーをお読みください。
- **한국어:** 이용 약관과 개인정보 처리방침을 읽어 주십시오.
- **简体中文：** 请阅读使用条款和隐私政策。
- **繁體中文：** 請閱讀使用條款和隱私權政策。
- **Русский:** Прочитайте условия использования и политику конфиденциальности.
- **Polski:** Przeczytaj warunki korzystania i politykę prywatności.
- **Türkçe:** Lütfen Kullanım Koşulları’nı ve Gizlilik Politikası’nı okuyun.
- **Українська:** Прочитайте умови використання та політику приватності.
- **العربية:** يُرجى قراءة شروط الاستخدام وسياسة الخصوصية.
- **हिन्दी:** कृपया उपयोग की शर्तें और गोपनीयता नीति पढ़ें।
