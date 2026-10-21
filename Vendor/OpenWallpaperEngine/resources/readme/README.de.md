Open Wallpaper Engine
=========

[English](../../README.md) | **Deutsch** | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine ist eine kostenlose Open-Source-App für macOS, die Wallpaper-Engine-Hintergrundbilder abspielt und bearbeitet: Szenen, Videos und Web. Szenen werden mit einem nativen Metal-Renderer gezeichnet, mit Effekten, Partikeln, 3D-Modellen, Beleuchtung, SceneScript und audioreaktiven Visuals, und der Steam Workshop ist integriert. Das Projekt begann als Fork von [Open Wallpaper Engine](https://github.com/MrWindDog) von Haren Chen und MrWindDog und wurde seitdem weitgehend neu geschrieben.

> **Hinweis:** Dieses Projekt steht in KEINER Verbindung zum kommerziellen Wallpaper Engine auf Steam. Es handelt sich um eine Open-Source-App für macOS, die Hintergrundbild-Assets aus dem Steam Workshop von Wallpaper Engine anzeigen kann. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Website:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki:** [Anleitungen und Fehlerbehebung](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![Die Mediathek](../../docs/images/library.jpg)

## Was die App auszeichnet

- **Die einzige macOS-App, die Wallpaper-Engine-Szenen bearbeitet.** Der Hintergrundbild-Editor öffnet die Ebenen, Effekte, Partikel, Zeitleiste und Skripte einer Szene und sichert sie als Wallpaper-Engine-Hintergrundbild.
- **Export als Live Photo und für Wallpaper Engine auf Android.** Jede Szene und jedes Video wird zu einem bewegten Sperrbildschirm für iPhone und iPad oder zu einem Paket für die Android-App von Wallpaper Engine.
- **Die eigenen Shader von Wallpaper Engine, übersetzt.** Jede Ebene, jeder Effekt und jedes Material wird mit den Original-Shadern des Hintergrundbilds gezeichnet, nach Metal übersetzt, auch Effekte, die Workshop-Autoren selbst geschrieben haben.
- **Ein vollständig live laufender Bildschirmschoner.** Der Bildschirmschoner zeichnet das Hintergrundbild jedes Displays, während es läuft, sodass sich Uhren, Skripte und audioreaktive Teile weiterbewegen. Nichts wird aufgezeichnet.

## Highlights

- **Szenen-, Video- und Web-Hintergrundbilder**: Szenen mit Effekten, Partikeln, 3D-Modellen, Lichtern, Zeitleisten, SceneScript und audioreaktiven Visuals sowie HDR-Ausgabe für Szenen und für HDR10- oder HLG-Videos auf Displays, die sie darstellen können. Web-Hintergrundbilder laufen in WebKit oder in der optionalen Chromium-Engine, mit ihren Ordnereigenschaften, Live-Audio und „Aktuelle Wiedergabe“.
- **Steam Workshop**: mit den Sortierungen und Filtern von Wallpaper Engine durchsuchen, über SteamCMD mit Ihrem eigenen Steam-Account laden oder Hintergrundbildordner und Zip-Dateien importieren. Der Tab „Installiert“ hat die Ordner und Sortierungen von Wallpaper Engine.
- **Hintergrundbild-Editor**: ein Editor nach dem Vorbild von Wallpaper Engine. Ebenen mit Gizmos hinzufügen und anordnen, Effekte mit Vorschauen hinzufügen, eigene Effekte im Shader-Editor schreiben und bearbeiten, FBX- und OBJ-Modelle importieren, auf einer Zeitleiste animieren, SceneScript schreiben, Benutzereigenschaften erstellen, Partikelsysteme und Puppet-Warp-Rigs bearbeiten und die Bildwerkzeuge von Wallpaper Engine nutzen (Vordergrund-Separation, Erstellung eines Character-Sheets, Generieren einer Normal-Map). **Neues Hintergrundbild …** beginnt eines aus einem Bild oder aus einer der Vorlagen von Wallpaper Engine. Sie bearbeiten einen Entwurf: **Sichern** übernimmt ihn, **Als neues Hintergrundbild sichern** fügt der Mediathek eine Kopie hinzu, und die eigenen Dateien des Hintergrundbilds werden nie verändert.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Hintergrundbild-Editor](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Szene bearbeiten/exportieren**: Ebenen und Effekte des laufenden Hintergrundbilds live auf dem Schreibtisch ändern, festlegen, was der Bildschirmschoner zeigt, oder das Hintergrundbild als Live Photo oder als Android-Paket exportieren.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Szene bearbeiten/exportieren](../../docs/images/scene-editor-live.jpg)

- **Bildschirmschoner und Sperrbildschirm**: Der Bildschirmschoner zeigt das Hintergrundbild jedes Displays live (*Bildschirmschoner wie Hintergrundbild*) oder eines, das Sie auswählen, und der Sperrbildschirm zeigt ein Bild davon.

  <!-- demo: screen-saver -->

- **Export**: Live-Photo-Sperrbildschirme für iPhone und iPad, per AirDrop gesendet oder in Fotos gesichert, sowie Android-Pakete von Wallpaper Engine, per QR-Code über WLAN an das Gerät gesendet.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Über WLAN senden](../../docs/images/send-over-wifi.png)

- **Displays**: ein Hintergrundbild pro Display, eines über alle gestreckt oder auf jedes geklont, Gruppen, Teilungen und Profile, wie in Wallpaper Engine. **In Fenster abspielen** spielt ein Hintergrundbild in einem eigenen Fenster ab.

  ![Displays](../../docs/images/displays.png)

- **Playlists**: Hintergrundbilder per Timer, bei der Anmeldung, nach Tageszeit oder Wochentag wechseln, mit den Übergängen von Wallpaper Engine.

  ![Playlist-Einstellungen](../../docs/images/playlists.png)

- **Steuerung**: Tastenkombinationen für Aktionen, Playlists, Hintergrundbilder und Display-Profile; die `-control`-[Befehlszeile](../../docs/command-line.md) von Wallpaper Engine; und das Plug-in **MCP-Server**, über das MCP-Clients Hintergrundbilder, Playlists und Einstellungen festlegen und Szenen bearbeiten, über eine lokale Verbindung, die nur Ihr Benutzeraccount öffnen kann.

  ![Plug-in MCP-Server](../../docs/images/mcp-plugin.png)

- **Energie**: Hintergrundbilder pausieren, solange der Bildschirm gesperrt ist, folgen der Regel *Laptop im Batteriebetrieb* von Wallpaper Engine und können im Batteriebetrieb oder im Stromsparmodus auf eine niedrigere Qualitätsvoreinstellung und Bildrate wechseln.
- **Farbanpassung**: Menüleiste, Akzentfarbe sowie eingefärbte Symbole und Ordner übernehmen die Farbe des Hintergrundbilds; die Fenster von Open Wallpaper Engine selbst können genau diese Farbe verwenden.

  ![Farbanpassung](../../docs/images/theming.png)

Alles Weitere, Bereich für Bereich: [docs/features.md](../../docs/features.md).

## Installation

1. Laden Sie die neueste Version von [openwallpaperengine.app](https://openwallpaperengine.app/) oder von [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases) herunter. Sie ist signiert und notarisiert und aktualisiert sich selbst.
2. Öffnen Sie das DMG und ziehen Sie **Open Wallpaper Engine** in den Ordner „Programme“.

Sie benötigen **macOS 14.0 (Sonoma) oder neuer**. Szenen-Hintergrundbilder benötigen die Wallpaper-Engine-Assets aus Ihrer eigenen Wallpaper-Engine-Kopie auf Steam; Video- und Web-Hintergrundbilder nicht. Manche Funktionen setzen eine neuere macOS-Version, eine Berechtigung oder ein Plug-in voraus: siehe [Erste Schritte](../../docs/getting-started.md#requirements).

## Schnellstart

1. Öffnen Sie die App. Der Einrichtungsassistent legt die Sprache, SteamCMD, Ihre Steam-Anmeldung und die Wallpaper-Engine-Assets fest und kann Ihre Wallpaper-Engine-Favoriten und -Ordner importieren; jeder Schritt lässt sich überspringen.
2. Installieren Sie die Wallpaper-Engine-Assets (*Einstellungen › Assets*), wenn Sie Szenen-Hintergrundbilder nutzen möchten. Sie stammen aus Ihrer eigenen Wallpaper-Engine-Kopie auf Steam; Video- und Web-Hintergrundbilder funktionieren ohne sie.
3. Hintergrundbilder finden Sie in den Tabs **Entdecken** und **Workshop**; Sie können auch einen Hintergrundbildordner oder eine Zip-Datei importieren (*Ablage › Hintergrundbild aus Ordner importieren …*, ⌘I) oder mit **Hintergrundbild hinzufügen › Neues Hintergrundbild …** eines erstellen.
4. Klicken Sie in der Mediathek auf ein Hintergrundbild und dann in seinen Details auf **Hintergrundbild festlegen** (oder klicken Sie es mit der rechten Maustaste an und wählen Sie **Als Hintergrundbild verwenden**). Seine Eigenschaften stehen darunter.

Mehr dazu: [Erste Schritte](../../docs/getting-started.md) und das [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Datenschutz

Alles, was die App speichert, bleibt auf Ihrem Mac, und sie sammelt keine Daten oder Analysen. Sie kontaktiert Steam (für den Workshop und die Assets), openwallpaperengine.app (um nach Updates zu suchen) und GitHub (um sie zu laden), und Plug-ins werden erst geladen, wenn Sie sie installieren. Details: [womit sich die App verbindet](../../docs/getting-started.md#what-the-app-connects-to) und die [Datenschutzrichtlinie](../../docs/legal/privacy-policy.md).

## Dokumentation

- [Erste Schritte](../../docs/getting-started.md) – Voraussetzungen, Assets, der Workshop und Importieren
- [Funktionen](../../docs/features.md) – alles, was die App unterstützt, und wie man es benutzt
- Anleitungen: [Display-Layouts](../../docs/display-layouts.md) · [Playlists](../../docs/playlists.md) · [Bildschirmschoner](../../docs/screen-saver.md) · [Export für iPhone & iPad](../../docs/iphone-ipad-export.md) · [Export für Android](../../docs/android-export.md) · [Tiefenkarten](../../docs/depth-maps.md) · [Theming](../../docs/theming.md) · [Modellimport](../../docs/model-import.md) · [Bildwerkzeuge](../../docs/image-tools.md) · [MCP-Server](../../docs/mcp.md) · [Befehlszeile](../../docs/command-line.md) · [Chromium-Web-Engine](../../docs/chromium-engine.md)
- [Entwicklung](../../docs/development.md) – aus dem Quellcode erstellen und die Projektstruktur; [CONTRIBUTING.md](../../CONTRIBUTING.md) und [Architektur](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) – Anleitungen, Einstellungsreferenz und Fehlerbehebung

## Verwandte Projekte

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** – Eine PyQt6-Oberfläche für [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) mit Steam-Workshop-Integration und einem von dieser macOS-Version übernommenen UI-Design.

## Danksagungen

Dieses Projekt baut auf der Arbeit folgender Personen auf:

- **[MrWindDog](https://github.com/MrWindDog)** – Maintainer des Upstream-Forks [wallpaper-engine-mac](https://github.com/MrWindDog), hat neue Funktionen und Verbesserungen der Benutzeroberfläche hinzugefügt
- **[Haren Chen](https://github.com/haren724)** – Ursprünglicher Entwickler von [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), hat die Kernarchitektur der App erstellt (SwiftUI, Wiedergabe von Video-Hintergrundbildern, Importsystem, Playlist-Oberfläche)
- **1ris_W** – Chinesische Übersetzung (i18n)
- **[Klaus Zhu](https://github.com/klauszhu1105)** – Ursprüngliches Logodesign
- **[Chen Chia Yang](https://github.com/Unayung)** – Rendern von Szenen-Hintergrundbildern, Korrekturen für Web-Hintergrundbilder, Steam-Workshop-Integration, Unterstützung mehrerer Displays, Zip-Import
- **[Deepratna Awale](https://github.com/deepratna-awale)** – Metal-Szenenrenderer und Effekt-Pipeline, Übersetzung und Caching von GLSL→MSL-Shadern, SceneScript-Laufzeitumgebung, audioreaktives Rendern, Überarbeitung von Workshop und Downloads, Platzierungs- und Leistungseinstellungen, Neugestaltung des Logos

Lizenziert unter [GPL-3.0](../../LICENSE), wie das ursprüngliche Projekt.

## Rechtliches

[Nutzungsbedingungen](../../docs/legal/terms-of-use.md) · [Datenschutzrichtlinie](../../docs/legal/privacy-policy.md) · [Sicherheitsrichtlinie](../../SECURITY.md)

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
