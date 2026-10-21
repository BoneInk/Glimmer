# Localization glossary

The terms every translation of Open Wallpaper Engine uses. A term is translated the same way
everywhere in a language (inflected as the grammar needs); a translator changes a term here
first, then in `OpenWallpaperEngine/Localizable.xcstrings`.

## How the terms were chosen

In order of precedence:

1. **Apple's macOS wording** for anything macOS also names: Settings, Wallpaper, Displays, Privacy
   & Security, Trash, Finder, Sidebar, Cancel/OK/Done… Checked against Apple's localized Mac User
   Guide and Support pages (linked per row) and against the strings macOS itself ships (the
   `.loctable` files of AppKit, SwiftUI, System Settings, Finder and Music on macOS 27, which is the
   data Apple publishes as its [localization glossaries](https://developer.apple.com/download/all/?q=glossary)).
2. **Steam's own wording** for the Workshop, subscribing and signing in, taken from Steam's
   localized pages (`?l=<language>` on steamcommunity.com) and its client strings. Steam's UI
   has no Hindi, and Arabic only in its client files; Hindi keeps "Workshop" in Latin script.
3. **Microsoft Terminology** (the Microsoft Terminology Collection, TBX) for general software terms
   Apple doesn't name: refresh, sort, anti-aliasing, frame rate, shader, texture.
4. **Wallpaper Engine's own UI** (`locale/ui_*.json` of a Wallpaper Engine install, or of the assets cache) for wallpaper-domain terms:
   scene, bloom, parallax, audio responsive, particle, age ratings.

**Age rating “Questionable”** is Wallpaper Engine's middle tier between Everyone and Mature
(mildly suggestive content, roughly PG-13), not “doubtful”. Neither Steam nor Wallpaper Engine
localizes the rating tags (Steam shows them in English, except its zh-Hant tag panel's 爭議性,
“controversial”), so each language uses its country's usual age-rating label for teen content
where one exists (FSK/USK, CERO, GRAC, Taiwan's 分級, 436-ФЗ, PEGI, RTÜK, ClassInd, CBFC), and
otherwise a short content term (fr Suggestif, es Sugerente, it Allusivo, zh-Hans 轻度暗示,
ar للمراهقين). The stored value stays `Questionable`.

Product names stay as the platforms write them: Open Wallpaper Engine, Wallpaper Engine, Steam,
Steam Guard, macOS, Finder (except where Apple translates it: 访达, فايندر).

## Sources

- macOS strings: the localized `.loctable` resources of macOS 27 (AppKit `MenuCommands`, System
  Settings extensions `Wallpaper`, `DesktopSettings`, `DisplaysExt`, Finder, Music), read with
  `plutil -convert json`.
- Apple Mac User Guide pages: `https://support.apple.com/<locale>/guide/mac-help/<page>/mac`
  (mchlp1103 Wallpaper, mh40768 Displays, mchld6aa7d23 Screen & System Audio Recording,
  mchl83c9e8b8 Finder sidebar, mchlp1093 Trash; mchlp1103 13.0 for the wallpaper arrangement
  options), KB `https://support.apple.com/<locale>/102610` (Move to Trash) and the Music guide
  `guide/music/mus2989`.
- Steam: `https://steamcommunity.com/workshop/browse/?appid=431960&l=<language>`,
  `https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=<language>`, the
  supported-language list at https://partner.steamgames.com/doc/store/localization/languages and
  the Steam client strings mirrored by SteamDB (`SteamTracking/ClientExtracted/steamui/localization`).
- Microsoft: https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology
  (Microsoft Terminology Collection, TBX files dated 2024-11-06).

## Style per language

| Language | Code | Address | Notes |
|---|---|---|---|
| German | de | Sie | Nouns capitalised, „…“ quotes |
| French | fr | vous | Sentence case, « … » with no-break spaces, no-break space before : ; ! ? |
| Spanish (Spain) | es | tú | Sentence case, ¿ ¡, «…» |
| Portuguese (Brazil) | pt-BR | você | Title Case for menu items and buttons, as Apple pt-BR |
| Italian | it | tu | Sentence case, ’ apostrophe |
| Japanese | ja | です／ます | 「」 quotes, full-width punctuation, Apple katakana (ユーザ, フォルダ) |
| Korean | ko | 합니다체 | Short noun labels, 창작마당 for Workshop |
| Chinese, Simplified | zh-Hans | — | Full-width punctuation, space between Chinese and Latin text |
| Chinese, Traditional | zh-Hant | — | Taiwan vocabulary, 「」 quotes |
| Russian | ru | вы | «…» quotes; “обои” is plural-only, counted as “Обоев: N” |
| Polish | pl | — | Imperative buttons, „…” quotes |
| Turkish | tr | siz | Title Case for menu items, ’ before suffixes on names |
| Ukrainian | uk | ви | «…» quotes, ʼ apostrophe |
| Arabic | ar | — | Modern Standard Arabic, right to left, ، ؟ |
| Hindi | hi | आप | Apple's Hindi with English loanwords in Devanagari |


## Deutsch (de)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | Hintergrundbild | [Apple](https://support.apple.com/de-de/guide/mac-help/mchlp1103/mac) |
| Settings | Einstellungen | [macOS strings](#sources) |
| System Settings | Systemeinstellungen | [Apple](https://support.apple.com/de-de/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Datenschutz & Sicherheit | [Apple](https://support.apple.com/de-de/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Aufnahme von Bildschirm & Systemaudio | [Apple](https://support.apple.com/de-de/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Aufnahme von Systemaudio | macOS System Settings (Privacy & Security) |
| Displays / display | Displays / Display | [Apple](https://support.apple.com/de-de/guide/mac-help/mh40768/mac) |
| Main display | Hauptbildschirm | [Apple](https://support.apple.com/de-de/guide/mac-help/mh40768/mac) |
| Desktop | Schreibtisch | [macOS strings](#sources) |
| Workshop / Steam Workshop | Workshop / Steam Workshop | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=german) |
| Subscribe / Unsubscribe | Abonnieren / Abbestellen | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=german) |
| Steam Guard code | Steam-Guard-Code | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_german.json) |
| Log In (to Steam) / Password | Anmelden / Passwort | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_german.json) |
| Download (verb) / Downloads (tab) | Laden / Downloads | [macOS strings](#sources) |
| Playlist | Playlist | [Apple Music](https://support.apple.com/de-de/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Zufällige Wiedergabe / Wiederholen | [Apple Music](https://support.apple.com/de-de/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Favoriten / Zu Favoriten hinzufügen | [Apple](https://support.apple.com/de-de/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Suchen / Filter / Sortieren nach / Aufsteigend / Absteigend | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Aktualisieren / Zurücksetzen | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Löschen / In den Papierkorb legen / Papierkorb | [Apple](https://support.apple.com/de-de/102610) · [Apple](https://support.apple.com/de-de/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Abbrechen / OK / Fertig | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Im Finder anzeigen | [macOS strings](#sources) |
| Sidebar / Inspector | Seitenleiste / Inspektor | [Apple](https://support.apple.com/de-de/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Vorschau | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Ton aus / Ton ein / Pause / Fortsetzen / Wiedergeben | [macOS strings](#sources) · WE `ui_de-de.json` |
| Scene / Video / Web / Application (wallpaper types) | Szene / Video / Web / Anwendung | WE `ui_de-de.json` |
| Particle / particle system | Partikel / Partikelsystem | WE `ui_de-de.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_de-de.json` |
| Parallax | Parallaxe | WE `ui_de-de.json` |
| Audio responsive | Audio-reaktiv | WE `ui_de-de.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Antialiasing / Post-Processing / Bildrate (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_de-de.json` |
| Texture / Shader / Material / Layer / Effect | Textur / Shader / Material / Ebene / Effekt | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_de-de.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Altersfreigabe: Jeder / Ab 12 / Nicht jugendfrei | WE `ui_de-de.json` · [FSK/USK „ab 12“](https://usk.de/alle-lernangebote/die-usk-alterskennzeichen/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Niedrige Auflösung | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Bildschirmfüllend / An Bildschirm anpassen / Zentriert / Bildschirmfüllend vergrößern / Zoomen | [Apple](https://support.apple.com/de-de/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Plug-ins / Diagnose / Berechtigungen / Leistung / Allgemein / Info | WE `ui_de-de.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Hintergrundbild-Speicher | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Szene bearbeiten/exportieren · Hintergrundbild-Editor | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Français (fr)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | fond d’écran | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchlp1103/mac) |
| Settings | Réglages | [macOS strings](#sources) |
| System Settings | Réglages Système | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Confidentialité et sécurité | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Enregistrement de l’écran et des sons du système | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Enregistrement des sons du système | macOS System Settings (Privacy & Security) |
| Displays / display | Moniteurs / moniteur | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mh40768/mac) |
| Main display | Écran principal | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mh40768/mac) |
| Desktop | bureau | [macOS strings](#sources) |
| Workshop / Steam Workshop | Workshop / Steam Workshop | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=french) |
| Subscribe / Unsubscribe | S’abonner / Se désabonner | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=french) |
| Steam Guard code | code Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_french.json) |
| Log In (to Steam) / Password | Se connecter / Mot de passe | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_french.json) |
| Download (verb) / Downloads (tab) | Télécharger / Téléchargements | [macOS strings](#sources) |
| Playlist | playlist | [Apple Music](https://support.apple.com/fr-fr/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Ordre aléatoire / Répéter | [Apple Music](https://support.apple.com/fr-fr/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Favoris / Ajouter aux favoris | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Rechercher / Filtrer / Trier par / Croissant / Décroissant | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Actualiser / Réinitialiser | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Supprimer / Placer dans la corbeille / Corbeille | [Apple](https://support.apple.com/fr-fr/102610) · [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Annuler / OK / Terminé | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Afficher dans le Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Barre latérale / Inspecteur | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Aperçu | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Couper le son / Réactiver le son / Pause / Reprendre / Lire | [macOS strings](#sources) · WE `ui_fr-fr.json` |
| Scene / Video / Web / Application (wallpaper types) | Scène / Vidéo / Web / Application | WE `ui_fr-fr.json` |
| Particle / particle system | Particule / système de particules | WE `ui_fr-fr.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Flou lumineux | WE `ui_fr-fr.json` |
| Parallax | Parallaxe | WE `ui_fr-fr.json` |
| Audio responsive | Réactif au son | WE `ui_fr-fr.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Anticrénelage / Post-traitement / Fréquence d’images (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_fr-fr.json` |
| Texture / Shader / Material / Layer / Effect | Texture / Nuanceur / Matériau / Calque / Effet | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_fr-fr.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Classification : Tout public / Suggestif / Adulte | WE `ui_fr-fr.json` · content term (suggestive); CSA ratings are ages only |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Basse résolution | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Occuper tout l’écran / Adapter à l’écran / Centrer / Étirer pour remplir l’écran / Zoomer | [Apple](https://support.apple.com/fr-fr/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Plug-ins / Diagnostic / Autorisations / Performances / Général / À propos | WE `ui_fr-fr.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Stockage des fonds d’écran | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Modifier/exporter la scène · Éditeur de fond d’écran | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Español (España) (es)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | fondo de pantalla | [Apple](https://support.apple.com/es-es/guide/mac-help/mchlp1103/mac) |
| Settings | Ajustes | [macOS strings](#sources) |
| System Settings | Ajustes del Sistema | [Apple](https://support.apple.com/es-es/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Privacidad y seguridad | [Apple](https://support.apple.com/es-es/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Grabación de pantalla y del audio del sistema | [Apple](https://support.apple.com/es-es/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Grabación del audio del sistema | macOS System Settings (Privacy & Security) |
| Displays / display | Pantallas / pantalla | [Apple](https://support.apple.com/es-es/guide/mac-help/mh40768/mac) |
| Main display | Pantalla principal | [Apple](https://support.apple.com/es-es/guide/mac-help/mh40768/mac) |
| Desktop | escritorio | [macOS strings](#sources) |
| Workshop / Steam Workshop | Workshop / Steam Workshop | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=spanish) |
| Subscribe / Unsubscribe | Suscribirse / Anular suscripción | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=spanish) |
| Steam Guard code | código de Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_spanish.json) |
| Log In (to Steam) / Password | Iniciar sesión / Contraseña | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_spanish.json) |
| Download (verb) / Downloads (tab) | Descargar / Descargas | [macOS strings](#sources) |
| Playlist | playlist | [Apple Music](https://support.apple.com/es-es/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Aleatorio / Repetir | [Apple Music](https://support.apple.com/es-es/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Favoritos / Añadir a favoritos | [Apple](https://support.apple.com/es-es/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Buscar / Filtrar / Ordenar por / Ascendente / Descendente | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Actualizar / Restablecer | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Eliminar / Trasladar a la papelera / Papelera | [Apple](https://support.apple.com/es-es/102610) · [Apple](https://support.apple.com/es-es/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Cancelar / Aceptar / OK | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Mostrar en el Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Barra lateral / Inspector | [Apple](https://support.apple.com/es-es/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Previsualización | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Silenciar / Activar sonido / Pausa / Reanudar / Reproducir | [macOS strings](#sources) · WE `ui_es-es.json` |
| Scene / Video / Web / Application (wallpaper types) | Escena / Vídeo / Web / Aplicación | WE `ui_es-es.json` |
| Particle / particle system | Partícula / sistema de partículas | WE `ui_es-es.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Resplandor | WE `ui_es-es.json` |
| Parallax | Paralaje | WE `ui_es-es.json` |
| Audio responsive | Reacciona al audio | WE `ui_es-es.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Suavizado de contorno / Posprocesado / Velocidad de fotogramas (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_es-es.json` |
| Texture / Shader / Material / Layer / Effect | Textura / Sombreador / Material / Capa / Efecto | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_es-es.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Clasificación: Todos / Sugerente / Adulto | WE `ui_es-es.json` · content term (suggestive); ICAA ratings are ages only |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Baja resolución | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Llenar pantalla / Ajustar a pantalla / Centrar / Ampliar para rellenar / Acercar | [Apple](https://support.apple.com/es-es/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Complementos / Diagnóstico / Permisos / Rendimiento / General / Acerca de | WE `ui_es-es.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Almacenamiento de fondos de pantalla | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Editar/exportar escena · Editor de fondos de pantalla | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Português (Brasil) (pt-BR)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | imagem de fundo | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchlp1103/mac) |
| Settings | Ajustes | [macOS strings](#sources) |
| System Settings | Ajustes do Sistema | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Privacidade e Segurança | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Gravação do Áudio do Sistema e da Tela | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Gravação do Áudio do Sistema | macOS System Settings (Privacy & Security) |
| Displays / display | Telas / tela | [Apple](https://support.apple.com/pt-br/guide/mac-help/mh40768/mac) |
| Main display | Tela principal | [Apple](https://support.apple.com/pt-br/guide/mac-help/mh40768/mac) |
| Desktop | mesa | [macOS strings](#sources) |
| Workshop / Steam Workshop | Oficina / Oficina Steam | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=brazilian) |
| Subscribe / Unsubscribe | Inscrever-se / Cancelar inscrição | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=brazilian) |
| Steam Guard code | código do Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_brazilian.json) |
| Log In (to Steam) / Password | Iniciar sessão / Senha | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_brazilian.json) |
| Download (verb) / Downloads (tab) | Baixar / Downloads | [macOS strings](#sources) |
| Playlist | playlist | [Apple Music](https://support.apple.com/pt-br/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Aleatório / Repetir | [Apple Music](https://support.apple.com/pt-br/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Favoritos / Adicionar aos Favoritos | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Buscar / Filtrar / Ordenar por / Crescente / Decrescente | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Atualizar / Redefinir | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Apagar / Mover para o Lixo / Lixo | [Apple](https://support.apple.com/pt-br/102610) · [Apple](https://support.apple.com/pt-br/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Cancelar / OK / OK | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Mostrar no Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Barra Lateral / Inspetor | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Pré-visualização | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Silenciar / Ativar Som / Pausar / Retomar / Reproduzir | [macOS strings](#sources) · WE `ui_pt-br.json` |
| Scene / Video / Web / Application (wallpaper types) | Cena / Vídeo / Web / Aplicativo | WE `ui_pt-br.json` |
| Particle / particle system | Partícula / sistema de partículas | WE `ui_pt-br.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_pt-br.json` |
| Parallax | Paralaxe | WE `ui_pt-br.json` |
| Audio responsive | Sensível a áudio | WE `ui_pt-br.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Suavização / Pós-processamento / Taxa de quadros (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_pt-br.json` |
| Texture / Shader / Material / Layer / Effect | Textura / Shader / Material / Camada / Efeito | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_pt-br.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Classificação: Livre / 12+ / Adulto | WE `ui_pt-br.json` · [ClassInd “12”](https://www.gov.br/mj/pt-br/assuntos/seus-direitos/classificacao-1) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Baixa Resolução | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Preencher Tela / Ajustar à Tela / Centralizar / Estender e Preencher Tela / Zoom | [Apple](https://support.apple.com/pt-br/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Plug-ins / Diagnóstico / Permissões / Desempenho / Geral / Sobre | WE `ui_pt-br.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Armazenamento de Imagens de Fundo | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Editar/Exportar Cena · Editor de Imagem de Fundo | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Italiano (it)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | sfondo | [Apple](https://support.apple.com/it-it/guide/mac-help/mchlp1103/mac) |
| Settings | Impostazioni | [macOS strings](#sources) |
| System Settings | Impostazioni di Sistema | [Apple](https://support.apple.com/it-it/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Privacy e sicurezza | [Apple](https://support.apple.com/it-it/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Registrazione schermo e audio di sistema | [Apple](https://support.apple.com/it-it/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Registrazione audio di sistema | macOS System Settings (Privacy & Security) |
| Displays / display | Schermi / schermo | [Apple](https://support.apple.com/it-it/guide/mac-help/mh40768/mac) |
| Main display | Schermo principale | [Apple](https://support.apple.com/it-it/guide/mac-help/mh40768/mac) |
| Desktop | scrivania | [macOS strings](#sources) |
| Workshop / Steam Workshop | Workshop / Steam Workshop | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=italian) |
| Subscribe / Unsubscribe | Sottoscrivi / Annulla sottoscrizione | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=italian) |
| Steam Guard code | codice di Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_italian.json) |
| Log In (to Steam) / Password | Accedi / Password | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_italian.json) |
| Download (verb) / Downloads (tab) | Scarica / Download | [macOS strings](#sources) |
| Playlist | playlist | [Apple Music](https://support.apple.com/it-it/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Casuale / Ripeti | [Apple Music](https://support.apple.com/it-it/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Preferiti / Aggiungi ai preferiti | [Apple](https://support.apple.com/it-it/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Cerca / Filtra / Ordina per / Crescente / Decrescente | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Aggiorna / Ripristina | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Elimina / Sposta nel Cestino / Cestino | [Apple](https://support.apple.com/it-it/102610) · [Apple](https://support.apple.com/it-it/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Annulla / OK / Fine | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Mostra nel Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Barra laterale / Inspector | [Apple](https://support.apple.com/it-it/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Anteprima | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Disattiva audio / Riattiva audio / Pausa / Riprendi / Riproduci | [macOS strings](#sources) · WE `ui_it-it.json` |
| Scene / Video / Web / Application (wallpaper types) | Scena / Video / Web / Applicazione | WE `ui_it-it.json` |
| Particle / particle system | Particella / sistema particellare | WE `ui_it-it.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_it-it.json` |
| Parallax | Parallasse | WE `ui_it-it.json` |
| Audio responsive | Reattivo all’audio | WE `ui_it-it.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Anti-aliasing / Post-elaborazione / Frequenza fotogrammi (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_it-it.json` |
| Texture / Shader / Material / Layer / Effect | Texture / Shader / Materiale / Livello / Effetto | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_it-it.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Classificazione: Per tutti / Allusivo / Per adulti | WE `ui_it-it.json` · content term (allusive): “suggestivo” means evocative in Italian |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Bassa risoluzione | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | A schermo pieno / Adatta allo schermo / Centro / Amplia per riempire lo schermo / Zoom | [Apple](https://support.apple.com/it-it/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Plug-in / Diagnosi / Autorizzazioni / Prestazioni / Generali / Informazioni | WE `ui_it-it.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Archivio sfondi | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Modifica/esporta scena · Editor sfondi | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## 日本語 (ja)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | 壁紙 | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchlp1103/mac) |
| Settings | 設定 | [macOS strings](#sources) |
| System Settings | システム設定 | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | プライバシーとセキュリティ | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | 画面収録とシステムオーディオ録音 | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | システムオーディオ録音 | macOS System Settings (Privacy & Security) |
| Displays / display | ディスプレイ | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mh40768/mac) |
| Main display | 主ディスプレイ | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mh40768/mac) |
| Desktop | デスクトップ | [macOS strings](#sources) |
| Workshop / Steam Workshop | ワークショップ / Steam ワークショップ | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=japanese) |
| Subscribe / Unsubscribe | サブスクライブ / 購読解除 | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=japanese) |
| Steam Guard code | Steamガードコード | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_japanese.json) |
| Log In (to Steam) / Password | ログイン / パスワード | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_japanese.json) |
| Download (verb) / Downloads (tab) | ダウンロード / ダウンロード | [macOS strings](#sources) |
| Playlist | プレイリスト | [Apple Music](https://support.apple.com/ja-jp/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | シャッフル / リピート | [Apple Music](https://support.apple.com/ja-jp/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | お気に入り / お気に入りに追加 | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | 検索 / フィルタ / 並べ替え / 昇順 / 降順 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | 更新 / リセット | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | 削除 / ゴミ箱に入れる / ゴミ箱 | [Apple](https://support.apple.com/ja-jp/102610) · [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | キャンセル / OK / 完了 | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Finderに表示 | [macOS strings](#sources) |
| Sidebar / Inspector | サイドバー / インスペクタ | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | プレビュー | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | 消音 / 消音解除 / 一時停止 / 再開 / 再生 | [macOS strings](#sources) · WE `ui_ja-jp.json` |
| Scene / Video / Web / Application (wallpaper types) | シーン / ビデオ / Web / アプリケーション | WE `ui_ja-jp.json` |
| Particle / particle system | パーティクル / パーティクルシステム | WE `ui_ja-jp.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | ブルーム | WE `ui_ja-jp.json` |
| Parallax | 視差 | WE `ui_ja-jp.json` |
| Audio responsive | オーディオレスポンス | WE `ui_ja-jp.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | アンチエイリアシング / ポストプロセッシング / フレームレート (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ja-jp.json` |
| Texture / Shader / Material / Layer / Effect | テクスチャ / シェーダー / マテリアル / レイヤー / エフェクト | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ja-jp.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | 年齢制限: 全年齢 / 12歳以上 / 成人向け | WE `ui_ja-jp.json` · [CERO B “12歳以上対象”](https://www.cero.gr.jp/publics/index/17/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | 低解像度 | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | 画面全体に表示 / 画面に収まるサイズで表示 / 中央に配置 / 引き伸ばして画面全体に表示 / ズーム | [Apple](https://support.apple.com/ja-jp/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | プラグイン / 診断 / アクセス権 / パフォーマンス / 一般 / 情報 | WE `ui_ja-jp.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | 壁紙の保存場所 | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | シーン編集/書き出し · 壁紙エディタ | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## 한국어 (ko)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | 배경화면 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchlp1103/mac) |
| Settings | 설정 | [macOS strings](#sources) |
| System Settings | 시스템 설정 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | 개인정보 보호 및 보안 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | 화면 및 시스템 오디오 녹음 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | 시스템 오디오 녹음 | macOS System Settings (Privacy & Security) |
| Displays / display | 디스플레이 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mh40768/mac) |
| Main display | 메인 디스플레이 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mh40768/mac) |
| Desktop | 데스크탑 | [macOS strings](#sources) |
| Workshop / Steam Workshop | 창작마당 / Steam 창작마당 | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=koreana) |
| Subscribe / Unsubscribe | 구독 / 구독 취소 | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=koreana) |
| Steam Guard code | Steam Guard 코드 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_koreana.json) |
| Log In (to Steam) / Password | 로그인 / 비밀번호 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_koreana.json) |
| Download (verb) / Downloads (tab) | 다운로드 / 다운로드 | [macOS strings](#sources) |
| Playlist | 플레이리스트 | [Apple Music](https://support.apple.com/ko-kr/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | 셔플 / 반복 | [Apple Music](https://support.apple.com/ko-kr/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | 즐겨찾기 / 즐겨찾기에 추가 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | 검색 / 필터 / 정렬 기준 / 오름차순 / 내림차순 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | 새로 고침 / 재설정 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | 삭제 / 휴지통으로 이동 / 휴지통 | [Apple](https://support.apple.com/ko-kr/102610) · [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | 취소 / 확인 / 완료 | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Finder에서 보기 | [macOS strings](#sources) |
| Sidebar / Inspector | 사이드바 / 인스펙터 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | 미리보기 | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | 소리 끔 / 소리 켬 / 일시 정지 / 재개 / 재생 | [macOS strings](#sources) · WE `ui_ko-kr.json` |
| Scene / Video / Web / Application (wallpaper types) | 장면 / 비디오 / 웹 / 응용 프로그램 | WE `ui_ko-kr.json` |
| Particle / particle system | 파티클 / 파티클 시스템 | WE `ui_ko-kr.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | 블룸 | WE `ui_ko-kr.json` |
| Parallax | 시차 | WE `ui_ko-kr.json` |
| Audio responsive | 오디오 응답 | WE `ui_ko-kr.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | 앤티앨리어싱 / 포스트 프로세싱 / 프레임 속도(FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ko-kr.json` |
| Texture / Shader / Material / Layer / Effect | 텍스처 / 셰이더 / 머티리얼 / 레이어 / 효과 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ko-kr.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | 연령 등급: 전체 이용가 / 12세 이용가 / 성인 | WE `ui_ko-kr.json` · [GRAC “12세 이용가”](https://www.grac.or.kr/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | 저해상도 | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | 화면 채우기 / 화면에 맞추기 / 중앙 정렬 / 전체 화면으로 펼치기 / 확대 | [Apple](https://support.apple.com/ko-kr/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | 플러그인 / 진단 / 권한 / 성능 / 일반 / 정보 | WE `ui_ko-kr.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | 배경화면 저장 공간 | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | 장면 편집/내보내기 · 배경화면 편집기 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## 简体中文 (zh-Hans)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | 墙纸 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchlp1103/mac) |
| Settings | 设置 | [macOS strings](#sources) |
| System Settings | 系统设置 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | 隐私与安全 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | 录屏与系统录音 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | 系统录音 | macOS System Settings (Privacy & Security) |
| Displays / display | 显示器 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mh40768/mac) |
| Main display | 主显示器 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mh40768/mac) |
| Desktop | 桌面 | [macOS strings](#sources) |
| Workshop / Steam Workshop | 创意工坊 / Steam 创意工坊 | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=schinese) |
| Subscribe / Unsubscribe | 订阅 / 取消订阅 | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=schinese) |
| Steam Guard code | Steam 令牌验证码 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_schinese.json) |
| Log In (to Steam) / Password | 登录 / 密码 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_schinese.json) |
| Download (verb) / Downloads (tab) | 下载 / 下载 | [macOS strings](#sources) |
| Playlist | 播放列表 | [Apple Music](https://support.apple.com/zh-cn/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | 随机播放 / 重复 | [Apple Music](https://support.apple.com/zh-cn/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | 个人收藏 / 添加到个人收藏 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | 搜索 / 筛选 / 排序方式 / 升序 / 降序 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | 刷新 / 重置 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | 删除 / 移到废纸篓 / 废纸篓 | [Apple](https://support.apple.com/zh-cn/102610) · [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | 取消 / 好 / 完成 | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | 在访达中显示 | [macOS strings](#sources) |
| Sidebar / Inspector | 边栏 / 检查器 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | 预览 | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | 静音 / 取消静音 / 暂停 / 继续 / 播放 | [macOS strings](#sources) · WE `ui_zh-chs.json` |
| Scene / Video / Web / Application (wallpaper types) | 场景 / 视频 / 网页 / 应用程序 | WE `ui_zh-chs.json` |
| Particle / particle system | 粒子 / 粒子系统 | WE `ui_zh-chs.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | 泛光 | WE `ui_zh-chs.json` |
| Parallax | 视差 | WE `ui_zh-chs.json` |
| Audio responsive | 音频响应 | WE `ui_zh-chs.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | 抗锯齿 / 后处理 / 帧速率 (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_zh-chs.json` |
| Texture / Shader / Material / Layer / Effect | 纹理 / 着色器 / 材质 / 图层 / 效果 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_zh-chs.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | 年龄分级：所有人 / 轻度暗示 / 成人 | WE `ui_zh-chs.json` · content term (mildly suggestive); no national rating system |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | 低分辨率 | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | 充满屏幕 / 适合于屏幕 / 居中 / 拉伸以充满屏幕 / 缩放 | [Apple](https://support.apple.com/zh-cn/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | 插件 / 诊断 / 权限 / 性能 / 通用 / 关于 | WE `ui_zh-chs.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | 墙纸存储位置 | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | 场景编辑/导出 · 墙纸编辑器 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## 繁體中文 (zh-Hant)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | 背景圖片 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchlp1103/mac) |
| Settings | 設定 | [macOS strings](#sources) |
| System Settings | 系統設定 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | 隱私權與安全性 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | 螢幕與系統錄音 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | 系統錄音 | macOS System Settings (Privacy & Security) |
| Displays / display | 顯示器 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mh40768/mac) |
| Main display | 主要顯示器 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mh40768/mac) |
| Desktop | 桌面 | [macOS strings](#sources) |
| Workshop / Steam Workshop | 工作坊 / Steam 工作坊 | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=tchinese) |
| Subscribe / Unsubscribe | 訂閱 / 取消訂閱 | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=tchinese) |
| Steam Guard code | Steam Guard 代碼 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_tchinese.json) |
| Log In (to Steam) / Password | 登入 / 密碼 | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_tchinese.json) |
| Download (verb) / Downloads (tab) | 下載 / 下載項目 | [macOS strings](#sources) |
| Playlist | 播放列表 | [Apple Music](https://support.apple.com/zh-tw/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | 隨機播放 / 重複播放 | [Apple Music](https://support.apple.com/zh-tw/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | 喜好項目 / 加入喜好項目 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | 搜尋 / 篩選 / 排序方式 / 遞增 / 遞減 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | 重新整理 / 重置 | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | 刪除 / 丟到垃圾桶 / 垃圾桶 | [Apple](https://support.apple.com/zh-tw/102610) · [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | 取消 / 好 / 完成 | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | 顯示於Finder | [macOS strings](#sources) |
| Sidebar / Inspector | 側邊欄 / 檢閱器 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | 預覽 | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | 靜音 / 取消靜音 / 暫停 / 繼續 / 播放 | [macOS strings](#sources) · WE `ui_zh-cht.json` |
| Scene / Video / Web / Application (wallpaper types) | 場景 / 影片 / 網頁 / 應用程式 | WE `ui_zh-cht.json` |
| Particle / particle system | 粒子 / 粒子系統 | WE `ui_zh-cht.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | 光暈 | WE `ui_zh-cht.json` |
| Parallax | 視差 | WE `ui_zh-cht.json` |
| Audio responsive | 音訊回應式 | WE `ui_zh-cht.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | 消除鋸齒 / 後處理 / 畫面播放速率 (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_zh-cht.json` |
| Texture / Shader / Material / Layer / Effect | 紋理 / 著色器 / 材質 / 圖層 / 效果 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_zh-cht.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | 年齡分級：全年齡 / 輔12級 / 成人 | WE `ui_zh-cht.json` · [Taiwan 分級 “輔12級”](https://law.moj.gov.tw/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | 低解析度 | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | 填滿螢幕 / 符合螢幕大小 / 置中 / 擴展至填滿螢幕 / 縮放 | [Apple](https://support.apple.com/zh-tw/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | 外掛程式 / 診斷 / 權限 / 效能 / 一般 / 關於 | WE `ui_zh-cht.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | 背景圖片儲存位置 | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | 場景編輯/輸出 · 背景圖片編輯器 | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Русский (ru)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | обои (plural-only noun) | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchlp1103/mac) |
| Settings | Настройки | [macOS strings](#sources) |
| System Settings | Системные настройки | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Конфиденциальность и безопасность | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Запись экрана и системного звука | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Системная аудиозапись | macOS System Settings (Privacy & Security) |
| Displays / display | Дисплеи / дисплей | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mh40768/mac) |
| Main display | Основной дисплей | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mh40768/mac) |
| Desktop | рабочий стол | [macOS strings](#sources) |
| Workshop / Steam Workshop | Мастерская / Мастерская Steam | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=russian) |
| Subscribe / Unsubscribe | Подписаться / Отписаться | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=russian) |
| Steam Guard code | код Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_russian.json) |
| Log In (to Steam) / Password | Войти / Пароль | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_russian.json) |
| Download (verb) / Downloads (tab) | Загрузить / Загрузки | [macOS strings](#sources) |
| Playlist | плейлист | [Apple Music](https://support.apple.com/ru-ru/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Перемешивать / Повторять | [Apple Music](https://support.apple.com/ru-ru/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Избранное / Добавить в избранное | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Поиск / Фильтр / Сортировать по / По возрастанию / По убыванию | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Обновить / Сбросить | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Удалить / Переместить в Корзину / Корзина | [Apple](https://support.apple.com/ru-ru/102610) · [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Отменить / ОК / Готово | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Показать в Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Боковое меню / Инспектор | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Предварительный просмотр | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Выключить звук / Включить звук / Пауза / Возобновить / Воспроизвести | [macOS strings](#sources) · WE `ui_ru-ru.json` |
| Scene / Video / Web / Application (wallpaper types) | Сцена / Видео / Веб / Приложение | WE `ui_ru-ru.json` |
| Particle / particle system | Частица / система частиц | WE `ui_ru-ru.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_ru-ru.json` |
| Parallax | Параллакс | WE `ui_ru-ru.json` |
| Audio responsive | Реагирующие на звук | WE `ui_ru-ru.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Сглаживание / Постобработка / Частота кадров (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ru-ru.json` |
| Texture / Shader / Material / Layer / Effect | Текстура / Шейдер / Материал / Слой / Эффект | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ru-ru.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Возрастной рейтинг: Для всех / 12+ / Для взрослых | WE `ui_ru-ru.json` · [436-ФЗ “12+”](http://www.consultant.ru/document/cons_doc_LAW_108808/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Низкое разрешение | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Во весь экран / По размеру экрана / По центру / Заполнить весь экран / Масштаб | [Apple](https://support.apple.com/ru-ru/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Плагины / Диагностика / Разрешения / Производительность / Основные / О программе | WE `ui_ru-ru.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Хранилище обоев | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Правка/экспорт сцены · Редактор обоев | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Polski (pl)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | tapeta | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchlp1103/mac) |
| Settings | Ustawienia | [macOS strings](#sources) |
| System Settings | Ustawienia systemowe | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Prywatność i ochrona | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Nagrywanie ekranu i dźwięku systemowego | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Nagrywanie dźwięku systemowego | macOS System Settings (Privacy & Security) |
| Displays / display | Wyświetlacze / wyświetlacz | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mh40768/mac) |
| Main display | Wyświetlacz główny | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mh40768/mac) |
| Desktop | biurko | [macOS strings](#sources) |
| Workshop / Steam Workshop | Warsztat / Warsztat Steam | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=polish) |
| Subscribe / Unsubscribe | Zasubskrybuj / Anuluj subskrypcję | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=polish) |
| Steam Guard code | kod Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_polish.json) |
| Log In (to Steam) / Password | Zaloguj się / Hasło | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_polish.json) |
| Download (verb) / Downloads (tab) | Pobierz / Pobrane | [macOS strings](#sources) |
| Playlist | playlista | [Apple Music](https://support.apple.com/pl-pl/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Pomieszaj / Powtarzaj | [Apple Music](https://support.apple.com/pl-pl/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Ulubione / Dodaj do ulubionych | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Szukaj / Filtruj / Sortuj według / Rosnąco / Malejąco | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Odśwież / Resetuj | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Usuń / Przenieś do Kosza / Kosz | [Apple](https://support.apple.com/pl-pl/102610) · [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Anuluj / OK / Gotowe | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Pokaż w Finderze | [macOS strings](#sources) |
| Sidebar / Inspector | Pasek boczny / Inspektor | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Podgląd | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Wycisz / Wyłącz wyciszenie / Wstrzymaj / Wznów / Odtwórz | [macOS strings](#sources) · WE `ui_pl-pl.json` |
| Scene / Video / Web / Application (wallpaper types) | Scena / Wideo / Sieć / Aplikacja | WE `ui_pl-pl.json` |
| Particle / particle system | Cząstka / system cząsteczek | WE `ui_pl-pl.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_pl-pl.json` |
| Parallax | Paralaksa | WE `ui_pl-pl.json` |
| Audio responsive | Reakcja na dźwięk | WE `ui_pl-pl.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Antyaliasing / Przetwarzanie końcowe / Liczba klatek (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_pl-pl.json` |
| Texture / Shader / Material / Layer / Effect | Tekstura / Shader / Materiał / Warstwa / Efekt | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_pl-pl.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Klasyfikacja wiekowa: Dla wszystkich / Od 12 lat / Dla dorosłych | WE `ui_pl-pl.json` · [PEGI “od 12 lat”](https://pegi.info/pl) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Niska rozdzielczość | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Wypełnij ekran / Dopasuj do ekranu / Na środku / Rozciągnij, aby wypełnić ekran / Powiększ | [Apple](https://support.apple.com/pl-pl/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Wtyczki / Diagnostyka / Uprawnienia / Wydajność / Ogólne / Informacje | WE `ui_pl-pl.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Magazyn tapet | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Edycja/eksport sceny · Edytor tapet | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Türkçe (tr)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | duvar kâğıdı | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchlp1103/mac) |
| Settings | Ayarlar | [macOS strings](#sources) |
| System Settings | Sistem Ayarları | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Gizlilik ve Güvenlik | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Ekran ve Sistem Sesi Kaydı | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Sistem Ses Kaydı | macOS System Settings (Privacy & Security) |
| Displays / display | Ekranlar / ekran | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mh40768/mac) |
| Main display | Ana ekran | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mh40768/mac) |
| Desktop | masaüstü | [macOS strings](#sources) |
| Workshop / Steam Workshop | Atölye / Steam Atölyesi | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=turkish) |
| Subscribe / Unsubscribe | Abone Ol / Abonelikten Çık | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=turkish) |
| Steam Guard code | Steam Guard kodu | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_turkish.json) |
| Log In (to Steam) / Password | Giriş Yap / Parola | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_turkish.json) |
| Download (verb) / Downloads (tab) | İndir / İndirilenler | [macOS strings](#sources) |
| Playlist | çalma listesi | [Apple Music](https://support.apple.com/tr-tr/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Karıştır / Yinele | [Apple Music](https://support.apple.com/tr-tr/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Favoriler / Favorilere Ekle | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Ara / Filtrele / Sıralama ölçütü / Artan / Azalan | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Yenile / Sıfırla | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Sil / Çöp Sepeti’ne Taşı / Çöp Sepeti | [Apple](https://support.apple.com/tr-tr/102610) · [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Vazgeç / Tamam / Bitti | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Finder’da Göster | [macOS strings](#sources) |
| Sidebar / Inspector | Kenar Çubuğu / Denetçi | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Önizleme | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Sesi Kapat / Sesi Aç / Duraklat / Sürdür / Oynat | [macOS strings](#sources) · WE `ui_tr-tr.json` |
| Scene / Video / Web / Application (wallpaper types) | Sahne / Video / Web / Uygulama | WE `ui_tr-tr.json` |
| Particle / particle system | Parçacık / parçacık sistemi | WE `ui_tr-tr.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom | WE `ui_tr-tr.json` |
| Parallax | Paralaks | WE `ui_tr-tr.json` |
| Audio responsive | Sese duyarlı | WE `ui_tr-tr.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Kenar yumuşatma / Son işleme / Kare hızı (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_tr-tr.json` |
| Texture / Shader / Material / Layer / Effect | Doku / Gölgelendirici / Malzeme / Katman / Efekt | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_tr-tr.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Yaş sınırı: Herkes / 13+ / Yetişkin | WE `ui_tr-tr.json` · [RTÜK Akıllı İşaretler “13+”](https://www.rtuk.gov.tr/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Düşük Çözünürlük | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Ekranı Doldur / Ekrana Sığdır / Ortala / Ekranı Dolduracak Şekilde Büyüt / Yakınlaştır | [Apple](https://support.apple.com/tr-tr/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Eklentiler / Tanılar / İzinler / Performans / Genel / Hakkında | WE `ui_tr-tr.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Duvar Kâğıdı Deposu | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Sahne Düzenle/Dışa Aktar · Duvar Kâğıdı Düzenleyici | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## Українська (uk)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | шпалера | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchlp1103/mac) |
| Settings | Параметри | [macOS strings](#sources) |
| System Settings | Системні параметри | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | Приватність і безпека | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | Записування системного звуку й екрана | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | Записування системного звуку | macOS System Settings (Privacy & Security) |
| Displays / display | Дисплеї / дисплей | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mh40768/mac) |
| Main display | Основний дисплей | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mh40768/mac) |
| Desktop | робочий стіл | [macOS strings](#sources) |
| Workshop / Steam Workshop | Майстерня / Майстерня Steam | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=ukrainian) |
| Subscribe / Unsubscribe | Підписатися / Відписатися | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=ukrainian) |
| Steam Guard code | код Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_ukrainian.json) |
| Log In (to Steam) / Password | Увійти / Пароль | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_ukrainian.json) |
| Download (verb) / Downloads (tab) | Викачати / Викачування | [macOS strings](#sources) |
| Playlist | список відтворення | [Apple Music](https://support.apple.com/uk-ua/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | Тасувати / Повторювати | [Apple Music](https://support.apple.com/uk-ua/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | Улюблені / Додати до улюблених | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | Пошук / Фільтр / Сортувати за / За зростанням / За спаданням | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | Оновити / Скинути | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | Видалити / Перемістити в Смітник / Смітник | [Apple](https://support.apple.com/uk-ua/102610) · [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | Скасувати / OK / Готово | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Показати у Finder | [macOS strings](#sources) |
| Sidebar / Inspector | Бічна панель / Інспектор | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | Попередній перегляд | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | Вимкнути звук / Увімкнути звук / Пауза / Поновити / Відтворити | [macOS strings](#sources) · WE `ui_uk-ua.json` |
| Scene / Video / Web / Application (wallpaper types) | Сцена / Відео / Веб / Програма | WE `ui_uk-ua.json` |
| Particle / particle system | Частинка / система частинок | WE `ui_uk-ua.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | Bloom-ефект | WE `ui_uk-ua.json` |
| Parallax | Паралакс | WE `ui_uk-ua.json` |
| Audio responsive | Реагують на звук | WE `ui_uk-ua.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | Згладжування / Постобробка / Частота кадрів (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_uk-ua.json` |
| Texture / Shader / Material / Layer / Effect | Текстура / Шейдер / Матеріал / Шар / Ефект | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_uk-ua.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | Вікова категорія: Для всіх / 12+ / Для дорослих | WE `ui_uk-ua.json` · age marking “12+” as in Ukrainian film/TV ratings |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | Низька роздільність | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | Заповнити екран / Припасувати до екрана / По центру / Розтягнути до заповнення екрана / Масштаб | [Apple](https://support.apple.com/uk-ua/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | Плагіни / Діагностика / Дозволи / Продуктивність / Загальні / Про програму | WE `ui_uk-ua.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | Сховище шпалер | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | Редагування/експорт сцени · Редактор шпалер | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## العربية (ar)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | خلفية الشاشة (short: خلفية) | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchlp1103/mac) |
| Settings | الإعدادات | [macOS strings](#sources) |
| System Settings | إعدادات النظام | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | الخصوصية والأمن | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | تسجيل الشاشة وصوت النظام | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | تسجيل صوت النظام | macOS System Settings (Privacy & Security) |
| Displays / display | شاشات العرض / شاشة العرض | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mh40768/mac) |
| Main display | شاشة العرض الرئيسية | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mh40768/mac) |
| Desktop | سطح المكتب | [macOS strings](#sources) |
| Workshop / Steam Workshop | الورشة / ورشة Steam | [Steam](https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&section=readytouseitems&l=arabic) |
| Subscribe / Unsubscribe | الاشتراك / إلغاء الاشتراك | [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3807436394&l=arabic) |
| Steam Guard code | رمز Steam Guard | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_arabic.json) |
| Log In (to Steam) / Password | تسجيل الدخول / كلمة المرور | [Steam client](https://raw.githubusercontent.com/SteamDatabase/SteamTracking/master/ClientExtracted/steamui/localization/shared_arabic.json) |
| Download (verb) / Downloads (tab) | تنزيل / التنزيلات | [macOS strings](#sources) |
| Playlist | قائمة تشغيل | [Apple Music](https://support.apple.com/ar-ae/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | خلط / تكرار | [Apple Music](https://support.apple.com/ar-ae/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | المفضلة / إضافة إلى المفضلة | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | بحث / تصفية / فرز حسب / تصاعدي / تنازلي | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | تحديث / إعادة تعيين | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | حذف / نقل إلى سلة المهملات / سلة المهملات | [Apple](https://support.apple.com/ar-ae/102610) · [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | إلغاء / حسنًا / تم | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | إظهار في فايندر | [macOS strings](#sources) |
| Sidebar / Inspector | الشريط الجانبي / المراقب | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | معاينة | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | كتم الصوت / إلغاء كتم الصوت / إيقاف مؤقت / استئناف / تشغيل | [macOS strings](#sources) · WE `ui_ar-sa.json` |
| Scene / Video / Web / Application (wallpaper types) | مشهد / فيديو / ويب / تطبيق | WE `ui_ar-sa.json` |
| Particle / particle system | جسيم / نظام جسيمات | WE `ui_ar-sa.json` · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | التوهج | WE `ui_ar-sa.json` |
| Parallax | اختلاف المنظر | WE `ui_ar-sa.json` |
| Audio responsive | تستجيب للصوت | WE `ui_ar-sa.json` |
| Anti-aliasing / Post-processing / Frame rate (FPS) | مانع التشويش / المعالجة اللاحقة / معدل الإطارات (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ar-sa.json` |
| Texture / Shader / Material / Layer / Effect | نسيج / مظلل / مادة / طبقة / تأثير | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE `ui_ar-sa.json` |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | التصنيف العمري: للجميع / للمراهقين / للبالغين | WE `ui_ar-sa.json` · content term (for teens); no common Arab rating label |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | دقة منخفضة | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | تعبئة الشاشة / الاحتواء ضمن الشاشة / الوسط / التمديد لتعبئة الشاشة / تكبير | [Apple](https://support.apple.com/ar-ae/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | الإضافات / التشخيصات / الأذونات / الأداء / عام / حول | WE `ui_ar-sa.json` · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | مخزن خلفيات الشاشة | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | تحرير/تصدير المشهد · محرر الخلفيات | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |

## हिन्दी (hi)

| Term | Translation | Source |
|---|---|---|
| Wallpaper (the item; also the macOS pane) | वॉलपेपर | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchlp1103/mac) |
| Settings | सेटिंग | [macOS strings](#sources) |
| System Settings | सिस्टम सेटिंग्ज़ | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchlp1103/mac) |
| Privacy & Security | गोपनीयता और सुरक्षा | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchld6aa7d23/mac) |
| Screen & System Audio Recording (macOS permission) | स्क्रीन और सिस्टम ऑडियो रिकॉर्डिंग | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchld6aa7d23/mac) |
| System Audio Recording (macOS permission) | सिस्टम ऑडियो रिकॉर्डिंग | macOS System Settings (Privacy & Security) |
| Displays / display | डिस्प्ले | [Apple](https://support.apple.com/hi-in/guide/mac-help/mh40768/mac) |
| Main display | मुख्य डिस्प्ले | [Apple](https://support.apple.com/hi-in/guide/mac-help/mh40768/mac) |
| Desktop | डेस्कटॉप | [macOS strings](#sources) |
| Workshop / Steam Workshop | Workshop / Steam Workshop (Steam has no Hindi UI) | Steam has no UI in this language |
| Subscribe / Unsubscribe | सब्सक्राइब करें / अनसब्सक्राइब करें | Steam has no UI in this language |
| Steam Guard code | Steam Guard कोड | Steam has no UI in this language |
| Log In (to Steam) / Password | लॉग इन करें / पासवर्ड | Steam has no UI in this language |
| Download (verb) / Downloads (tab) | डाउनलोड करें / डाउनलोड | [macOS strings](#sources) |
| Playlist | प्लेलिस्ट | [Apple Music](https://support.apple.com/hi-in/guide/music/mus2989/mac) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Shuffle / Repeat | शफ़ल / दोहराएँ | [Apple Music](https://support.apple.com/hi-in/guide/music/mus2989/mac) |
| Favorites (My Favourites, Add to Favorites) | पसंदीदा / पसंदीदा में जोड़ें | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchl83c9e8b8/mac) |
| Search / Filter / Sort By / Ascending / Descending | खोजें / फ़िल्टर / इसके अनुसार सॉर्ट करें / आरोही / अवरोही | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Refresh / Reset | रीफ़्रेश करें / रीसेट करें | [macOS strings](#sources) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Delete / Move to Trash / Trash | डिलीट करें / रद्दी में मूव करें / रद्दी | [Apple](https://support.apple.com/hi-in/102610) · [Apple](https://support.apple.com/hi-in/guide/mac-help/mchlp1093/mac) |
| Cancel / OK / Done | रद्द करें / ठीक है / पूर्ण | [macOS strings](#sources) |
| Show in Finder (Open in Finder) | Finder में दिखाएँ | [macOS strings](#sources) |
| Sidebar / Inspector | साइडबार / इंस्पेक्टर | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchl83c9e8b8/mac) · [macOS strings](#sources) |
| Preview | प्रीव्यू | [macOS strings](#sources) |
| Mute / Unmute / Pause / Resume / Play | म्यूट करें / अनम्यूट करें / पॉज़ करें / जारी रखें / चलाएँ | [macOS strings](#sources) · WE (no file for this language) |
| Scene / Video / Web / Application (wallpaper types) | सीन / वीडियो / वेब / ऐप | WE (no file for this language) |
| Particle / particle system | पार्टिकल / पार्टिकल सिस्टम | WE (no file for this language) · [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) |
| Bloom (glow effect) | ब्लूम | WE (no file for this language) |
| Parallax | पैरालैक्स | WE (no file for this language) |
| Audio responsive | ऑडियो पर प्रतिक्रिया | WE (no file for this language) |
| Anti-aliasing / Post-processing / Frame rate (FPS) | एंटीएलियासिंग / पोस्ट-प्रोसेसिंग / फ़्रेम दर (FPS) | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE (no file for this language) |
| Texture / Shader / Material / Layer / Effect | टेक्सचर / शेडर / मटीरियल / लेयर / इफ़ेक्ट | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) · WE (no file for this language) |
| Age rating: Everyone / Questionable (the middle tier, PG-13-like: mildly suggestive) / Mature | आयु रेटिंग: सभी / UA 13+ / वयस्क | WE (no file for this language) · [CBFC “UA 13+”](https://www.cbfcindia.gov.in/) |
| Low resolution (the 1 pixel per point render option, as in Get Info › Open in Low Resolution) | निम्न रिज़ोल्यूशन | [macOS strings](#sources) |
| Placement: Fill (=Fill Screen) / Fit (=Fit to Screen) / Center / Stretch (=Stretch to Fill Screen) / Zoom | फ़ुल स्क्रीन / स्क्रीन पर फ़िट करें / सेंटर / फ़ुल स्क्रीन पर स्ट्रेच करें / ज़ूम | [Apple](https://support.apple.com/hi-in/guide/mac-help/mchlp1103/13.0/mac/13.0) |
| Plugins / Diagnostics / Permissions / Performance / General / About | प्लग-इन / डायग्नॉस्टिक / अनुमतियाँ / परफ़ॉर्मेंस / सामान्य / जानकारी | WE (no file for this language) · [macOS strings](#sources) |
| Wallpaper Storage (the library-folder setting) | वॉलपेपर स्टोरेज | derived from “Wallpaper” |
| Scene Edit / Export · Wallpaper Editor (the app’s two editing windows; formerly “Scene Editor (Live)”, before that “Scene Inspector”; in inflected text, quote the first as a window title) | सीन एडिट/एक्सपोर्ट · वॉलपेपर एडिटर | [Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) (editor) · derived from “Scene”, “Edit” and “Export” |
