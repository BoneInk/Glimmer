Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | **Polski** | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine to darmowa aplikacja open source dla macOS, która odtwarza i edytuje tapety Wallpaper Engine: sceny, wideo i tapety internetowe. Sceny są rysowane natywnym rendererem Metal, z efektami, cząsteczkami, modelami 3D, oświetleniem, SceneScript i wizualizacjami reagującymi na dźwięk, a Warsztat Steam jest wbudowany. Powstała jako fork [Open Wallpaper Engine](https://github.com/MrWindDog) autorstwa Harena Chena i MrWindDoga, a od tamtej pory została w dużej mierze przepisana.

> **Uwaga:** Ten projekt NIE jest powiązany z komercyjnym programem Wallpaper Engine dostępnym w Steam. To aplikacja open source dla macOS, która potrafi wyświetlać zasoby tapet z Warsztatu Steam programu Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Strona internetowa:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki:** [poradniki i rozwiązywanie problemów](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![Biblioteka](../../docs/images/library.jpg)

## Co ją wyróżnia

- **Jedyna aplikacja na macOS, która edytuje sceny Wallpaper Engine.** Edytor tapet otwiera warstwy, efekty, cząsteczki, oś czasu i skrypty sceny oraz zapisuje ją jako tapetę Wallpaper Engine.
- **Eksport do Live Photo i do Wallpaper Engine na Androida.** Każda scena lub wideo staje się ruchomym ekranem blokady dla iPhone’a i iPada albo pakietem dla aplikacji Wallpaper Engine na Androida.
- **Własne shadery Wallpaper Engine, przetłumaczone.** Każda warstwa, efekt i materiał jest rysowany oryginalnymi shaderami tapety, przetłumaczonymi na Metal, w tym efekty, które autorzy z Warsztatu napisali samodzielnie.
- **Wygaszacz ekranu w pełni na żywo.** Wygaszacz ekranu rysuje tapetę każdego wyświetlacza w trakcie jej działania, więc zegary, skrypty i elementy reagujące na dźwięk wciąż się poruszają. Nic nie jest nagrywane.

## Najważniejsze funkcje

- **Tapety typu scena, wideo i internetowe**: sceny z efektami, cząsteczkami, modelami 3D, światłami, osiami czasu, SceneScript i wizualizacjami reagującymi na dźwięk oraz wyjście HDR dla scen i filmów HDR10 lub HLG na wyświetlaczach, które potrafią je pokazać. Tapety internetowe działają w WebKit lub w opcjonalnym silniku Chromium, z właściwościami swojego folderu, dźwiękiem na żywo i funkcją Teraz odtwarzane.
- **Warsztat Steam**: przeglądaj z sortowaniem i filtrami Wallpaper Engine, pobieraj przez SteamCMD z własnego konta Steam albo importuj foldery i pliki zip z tapetami. Karta Zainstalowane ma foldery i sortowanie Wallpaper Engine.
- **Edytor tapet**: edytor wzorowany na edytorze Wallpaper Engine. Dodawaj i rozmieszczaj warstwy za pomocą uchwytów, dodawaj efekty z podglądem, pisz i edytuj własne efekty w Edytorze shaderów, importuj modele FBX i OBJ, animuj na osi czasu, pisz SceneScript, twórz właściwości użytkownika, edytuj systemy cząsteczek i szkielety Puppet Warp oraz korzystaj z narzędzi do obrazów Wallpaper Engine (Oddzielenie pierwszego planu, Stworzenie karty postaci, Generowanie mapy normalnych). **Nowa tapeta…** tworzy tapetę z obrazu lub z jednego z szablonów Wallpaper Engine. Edytujesz wersję roboczą: **Zachowaj** ją stosuje, **Zachowaj jako nową tapetę** dodaje kopię do biblioteki, a własne pliki tapety nigdy nie są zmieniane.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Edytor tapet](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Edycja/eksport sceny**: zmieniaj na żywo, na biurku, warstwy i efekty działającej tapety, wybierz, co pokazuje wygaszacz ekranu, albo wyeksportuj tapetę jako Live Photo lub pakiet na Androida.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Edycja/eksport sceny](../../docs/images/scene-editor-live.jpg)

- **Wygaszacz ekranu i ekran blokady**: wygaszacz ekranu pokazuje na żywo tapetę każdego wyświetlacza (*Wygaszacz ekranu taki sam jak tapeta*) albo wybraną przez Ciebie, a ekran blokady pokazuje jej obraz.

  <!-- demo: screen-saver -->

- **Eksport**: ekrany blokady Live Photo dla iPhone’a i iPada, wysyłane przez AirDrop lub zapisywane w Zdjęciach, oraz pakiety Wallpaper Engine na Androida, wysyłane na urządzenie przez Wi-Fi za pomocą kodu QR.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Wysyłanie przez Wi-Fi](../../docs/images/send-over-wifi.png)

- **Wyświetlacze**: osobna tapeta na każdym wyświetlaczu, jedna rozciągnięta na wszystkie lub sklonowana na każdy, grupy, podziały i profile, tak jak w Wallpaper Engine. **Odtwórz w oknie** odtwarza tapetę we własnym oknie.

  ![Wyświetlacze](../../docs/images/displays.png)

- **Playlisty**: zmieniaj tapety według minutnika, przy logowaniu, o określonej porze dnia lub w wybrane dni tygodnia, z przejściami z Wallpaper Engine.

  ![Ustawienia playlisty](../../docs/images/playlists.png)

- **Sterowanie**: klawisze dostępu dla akcji, playlist, tapet i profili wyświetlaczy; [wiersz poleceń](../../docs/command-line.md) `-control` z Wallpaper Engine; oraz wtyczka **Serwer MCP**, przez którą klienty MCP ustawiają tapety, playlisty i ustawienia oraz edytują sceny, przez lokalne połączenie, które może otworzyć tylko Twoje konto.

  ![Wtyczka Serwer MCP](../../docs/images/mcp-plugin.png)

- **Zasilanie**: tapety wstrzymują się, gdy ekran jest zablokowany, stosują regułę *Laptop na baterii* z Wallpaper Engine i mogą przejść na niższy preset jakości i niższą liczbę klatek na baterii lub w trybie niskiego zużycia energii.
- **Motyw kolorów**: pasek menu, kolor akcentu oraz zabarwione ikony i foldery dopasowują się do koloru tapety; własne okna Open Wallpaper Engine mogą używać dokładnie tego koloru.

  ![Motyw kolorów](../../docs/images/theming.png)

Wszystko inne, obszar po obszarze: [docs/features.md](../../docs/features.md).

## Instalacja

1. Pobierz najnowsze wydanie ze strony [openwallpaperengine.app](https://openwallpaperengine.app/) lub z [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). Jest podpisane i poświadczone notarialnie przez Apple, a do tego samo się aktualizuje.
2. Otwórz plik DMG i przeciągnij **Open Wallpaper Engine** do folderu Aplikacje.

Potrzebujesz **macOS 14.0 (Sonoma) lub nowszego**. Tapety typu scena wymagają zasobów Wallpaper Engine z Twojej własnej kopii Wallpaper Engine w Steam; tapety wideo i internetowe ich nie wymagają. Niektóre funkcje wymagają nowszej wersji macOS, uprawnienia lub wtyczki: zobacz [Pierwsze kroki](../../docs/getting-started.md#requirements).

## Szybki start

1. Otwórz aplikację. Asystent konfiguracji ustawia język, SteamCMD, logowanie do Steam i zasoby Wallpaper Engine, a także może zaimportować Twoje ulubione i foldery z Wallpaper Engine; każdy krok można pominąć.
2. Zainstaluj zasoby Wallpaper Engine (*Ustawienia › Zasoby*), jeśli chcesz korzystać z tapet typu scena. Pochodzą one z Twojej własnej kopii Wallpaper Engine w Steam; tapety wideo i internetowe działają bez nich.
3. Znajdź tapety na kartach **Odkryj** i **Warsztat**, zaimportuj folder lub plik zip z tapetą (*Plik › Importuj tapetę z folderu…*, ⌘I) albo utwórz tapetę za pomocą **Dodaj tapetę › Nowa tapeta…**.
4. Kliknij tapetę w bibliotece, a następnie **Ustaw tapetę** w jej szczegółach (albo kliknij ją prawym przyciskiem i wybierz **Ustaw jako tapetę**). Jej właściwości są wymienione poniżej.

Więcej: [Pierwsze kroki](../../docs/getting-started.md) i [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Prywatność

Wszystko, co zapisuje aplikacja, zostaje na Twoim Macu, a ona sama nie zbiera żadnych danych ani statystyk. Łączy się ze Steam (w celu obsługi Warsztatu i zasobów), z openwallpaperengine.app (aby sprawdzać aktualizacje) i z GitHubem (aby je pobierać), a wtyczki są pobierane dopiero wtedy, gdy je zainstalujesz. Szczegóły: [z czym łączy się aplikacja](../../docs/getting-started.md#what-the-app-connects-to) oraz [polityka prywatności](../../docs/legal/privacy-policy.md).

## Dokumentacja

- [Pierwsze kroki](../../docs/getting-started.md) — wymagania, zasoby, Warsztat i importowanie
- [Funkcje](../../docs/features.md) — wszystko, co obsługuje aplikacja, i jak z tego korzystać
- Poradniki: [układy wyświetlaczy](../../docs/display-layouts.md) · [playlisty](../../docs/playlists.md) · [wygaszacz ekranu](../../docs/screen-saver.md) · [eksport na iPhone’a i iPada](../../docs/iphone-ipad-export.md) · [eksport na Androida](../../docs/android-export.md) · [mapy głębi](../../docs/depth-maps.md) · [motywy](../../docs/theming.md) · [import modeli](../../docs/model-import.md) · [narzędzia do obrazów](../../docs/image-tools.md) · [Serwer MCP](../../docs/mcp.md) · [wiersz poleceń](../../docs/command-line.md) · [silnik internetowy Chromium](../../docs/chromium-engine.md)
- [Rozwój](../../docs/development.md) — kompilowanie ze źródeł i struktura projektu; [CONTRIBUTING.md](../../CONTRIBUTING.md) i [architektura](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — poradniki, opis ustawień i rozwiązywanie problemów

## Powiązane projekty

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — graficzny interfejs w PyQt6 dla [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) z integracją z Warsztatem Steam i interfejsem przeniesionym z tej wersji dla macOS.

## Podziękowania

Ten projekt powstał na bazie pracy następujących osób:

- **[MrWindDog](https://github.com/MrWindDog)** — opiekun nadrzędnego forka [wallpaper-engine-mac](https://github.com/MrWindDog); dodał nowe funkcje i dopracował interfejs
- **[Haren Chen](https://github.com/haren724)** — twórca oryginalnego projektu [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac); zbudował podstawową architekturę aplikacji (SwiftUI, odtwarzanie tapet wideo, system importu, interfejs playlist)
- **1ris_W** — tłumaczenie na język chiński
- **[Klaus Zhu](https://github.com/klauszhu1105)** — oryginalny projekt logo
- **[Chen Chia Yang](https://github.com/Unayung)** — renderowanie tapet typu scena, poprawki tapet internetowych, integracja z Warsztatem Steam, obsługa wielu wyświetlaczy, import plików zip
- **[Deepratna Awale](https://github.com/deepratna-awale)** — renderer scen i potok efektów w Metal, tłumaczenie shaderów GLSL→MSL i ich buforowanie, środowisko uruchomieniowe SceneScript, renderowanie reagujące na dźwięk, przebudowa Warsztatu i pobierania, ustawienia rozmieszczenia i wydajności, przeprojektowanie logo

Projekt jest udostępniany na licencji [GPL-3.0](../../LICENSE), tak samo jak projekt oryginalny.

## Informacje prawne

[Warunki korzystania](../../docs/legal/terms-of-use.md) · [Polityka prywatności](../../docs/legal/privacy-policy.md) · [Zasady bezpieczeństwa](../../SECURITY.md)

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
