Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | **Français** | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine est une app macOS gratuite et open source qui lit et modifie les fonds d’écran Wallpaper Engine : scène, vidéo et web. Les scènes sont dessinées par un moteur de rendu Metal natif, avec effets, particules, modèles 3D, éclairage, SceneScript et visuels réactifs à l’audio, et le Steam Workshop est intégré. Elle est née d’un fork d’[Open Wallpaper Engine](https://github.com/MrWindDog) de Haren Chen et MrWindDog, et a depuis été en grande partie réécrite.

> **Remarque :** ce projet n’est PAS affilié au logiciel commercial Wallpaper Engine vendu sur Steam. Il s’agit d’une app open source pour macOS capable d’afficher les ressources de fonds d’écran du Steam Workshop de Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Site web :** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki :** [guides et dépannage](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![La bibliothèque](../../docs/images/library.jpg)

## Ce qui le distingue

- **La seule app macOS qui modifie les scènes Wallpaper Engine.** L’Éditeur de fond d’écran ouvre les calques, les effets, les particules, la chronologie et les scripts d’une scène, et l’enregistre comme fond d’écran Wallpaper Engine.
- **Exportation en Live Photo et pour Wallpaper Engine sur Android.** Toute scène ou vidéo devient un écran verrouillé animé pour iPhone et iPad, ou un paquet pour l’app Android de Wallpaper Engine.
- **Les propres nuanceurs de Wallpaper Engine, traduits.** Chaque calque, effet et matériau est dessiné avec les nuanceurs d’origine du fond d’écran, traduits en Metal, y compris les effets que les auteurs du Workshop ont écrits eux-mêmes.
- **Un économiseur d’écran entièrement en direct.** L’économiseur d’écran dessine le fond d’écran de chaque moniteur pendant qu’il s’exécute, de sorte que les horloges, les scripts et les éléments réactifs à l’audio continuent de bouger. Rien n’est enregistré.

## Points forts

- **Fonds d’écran de scène, vidéo et web** : des scènes avec effets, particules, modèles 3D, lumières, chronologies, SceneScript et visuels réactifs à l’audio, et une sortie HDR pour les scènes et les vidéos HDR10 ou HLG sur les moniteurs capables de l’afficher. Les fonds d’écran web s’exécutent dans WebKit ou dans le moteur Chromium facultatif, avec les propriétés de leur dossier, l’audio en direct et À l’écoute.
- **Steam Workshop** : parcourez avec les tris et les filtres de Wallpaper Engine, téléchargez via SteamCMD avec votre propre compte Steam, ou importez des dossiers et des fichiers zip de fonds d’écran. L’onglet Installés propose les dossiers et les tris de Wallpaper Engine.
- **Éditeur de fond d’écran** : un éditeur dans l’esprit de celui de Wallpaper Engine. Ajoutez et disposez des calques avec des gizmos, ajoutez des effets avec aperçus, écrivez et modifiez vos propres effets dans l’Éditeur de nuanceurs, importez des modèles FBX et OBJ, animez sur une chronologie, écrivez du SceneScript, créez des propriétés utilisateur, modifiez des systèmes de particules et des armatures Puppet Warp, et utilisez les outils d’image de Wallpaper Engine (Séparation premier plan, Création feuille du personnage, Génération de carte normale). **Nouveau fond d’écran…** en crée un à partir d’une image ou de l’un des modèles de Wallpaper Engine. Vous modifiez un brouillon : **Enregistrer** l’applique, **Enregistrer comme nouveau fond d’écran** en ajoute une copie à la bibliothèque, et les fichiers du fond d’écran lui-même ne sont jamais modifiés.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Éditeur de fond d’écran](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Modifier/exporter la scène** : modifiez en direct sur le bureau les calques et les effets du fond d’écran en cours, choisissez ce qu’affiche l’économiseur d’écran, ou exportez le fond d’écran en Live Photo ou en paquet Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Modifier/exporter la scène](../../docs/images/scene-editor-live.jpg)

- **Économiseur d’écran et écran verrouillé** : l’économiseur d’écran affiche en direct le fond d’écran de chaque moniteur (*Économiseur d’écran identique au fond d’écran*), ou celui que vous choisissez, et l’écran verrouillé en affiche une image.

  <!-- demo: screen-saver -->

- **Exportation** : écrans verrouillés Live Photo pour iPhone et iPad, envoyés par AirDrop ou enregistrés dans Photos, et paquets Android de Wallpaper Engine, envoyés à l’appareil par Wi-Fi grâce à un code QR.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Envoyer par Wi-Fi](../../docs/images/send-over-wifi.png)

- **Moniteurs** : un fond d’écran par moniteur, un seul étiré sur tous ou cloné sur chacun, des groupes, des divisions et des profils, comme dans Wallpaper Engine. **Lire dans une fenêtre** lit un fond d’écran dans sa propre fenêtre.

  ![Moniteurs](../../docs/images/displays.png)

- **Playlists** : changez de fond d’écran selon une minuterie, à l’ouverture de session, selon l’heure ou le jour de la semaine, avec les transitions de Wallpaper Engine.

  ![Réglages des playlists](../../docs/images/playlists.png)

- **Contrôle** : des raccourcis pour les actions, les playlists, les fonds d’écran et les profils de moniteurs ; la [ligne de commande](../../docs/command-line.md) `-control` de Wallpaper Engine ; et le plug-in **Serveur MCP**, grâce auquel les clients MCP définissent les fonds d’écran, les playlists et les réglages et modifient les scènes, via une connexion locale que seul votre compte peut ouvrir.

  ![Plug-in Serveur MCP](../../docs/images/mcp-plugin.png)

- **Énergie** : les fonds d’écran se mettent en pause quand l’écran est verrouillé, suivent la règle *Portable sur batterie* de Wallpaper Engine, et peuvent passer à un préréglage de qualité et à une fréquence d’images plus bas sur batterie ou en mode Économie d’énergie.
- **Thème de couleur** : la barre des menus, la couleur d’accentuation ainsi que les icônes et les dossiers teintés suivent la couleur du fond d’écran ; les fenêtres d’Open Wallpaper Engine peuvent utiliser la couleur exacte.

  ![Thème de couleur](../../docs/images/theming.png)

Tout le reste, domaine par domaine : [docs/features.md](../../docs/features.md).

## Installation

1. Téléchargez la dernière version sur [openwallpaperengine.app](https://openwallpaperengine.app/) ou sur [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). Elle est signée et notariée, et se met à jour toute seule.
2. Ouvrez le DMG et faites glisser **Open Wallpaper Engine** dans Applications.

Il vous faut **macOS 14.0 (Sonoma) ou version ultérieure**. Les fonds d’écran de scène nécessitent les ressources de Wallpaper Engine issues de votre propre exemplaire de Wallpaper Engine sur Steam ; les fonds d’écran vidéo et web, non. Certaines fonctionnalités nécessitent une version plus récente de macOS, une autorisation ou un plug-in : voir [Prise en main](../../docs/getting-started.md#requirements).

## Démarrage rapide

1. Ouvrez l’app. L’assistant de configuration règle la langue, SteamCMD, votre connexion Steam et les ressources de Wallpaper Engine, et peut importer vos favoris et vos dossiers Wallpaper Engine ; chaque étape peut être ignorée.
2. Installez les ressources de Wallpaper Engine (*Réglages › Ressources*) si vous voulez des fonds d’écran de scène. Elles proviennent de votre propre exemplaire de Wallpaper Engine sur Steam ; les fonds d’écran vidéo et web fonctionnent sans elles.
3. Trouvez des fonds d’écran dans les onglets **Découvrir** et **Workshop**, importez un dossier ou un fichier zip de fond d’écran (*Fichier › Importer un fond d’écran depuis un dossier…*, ⌘I), ou créez-en un avec **Ajouter un fond d’écran › Nouveau fond d’écran…**.
4. Cliquez sur un fond d’écran dans la bibliothèque, puis sur **Définir le fond d’écran** dans ses détails (ou cliquez dessus avec le bouton droit et choisissez **Définir comme fond d’écran**). Ses propriétés sont listées en dessous.

Pour aller plus loin : [Prise en main](../../docs/getting-started.md) et le [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Confidentialité

Tout ce que l’app enregistre reste sur votre Mac, et elle ne collecte aucune donnée ni statistique d’utilisation. Elle contacte Steam (pour le Workshop et les ressources), openwallpaperengine.app (pour rechercher les mises à jour) et GitHub (pour les télécharger), et les plug-ins ne sont téléchargés que lorsque vous les installez. Détails : [ce à quoi l’app se connecte](../../docs/getting-started.md#what-the-app-connects-to) et la [politique de confidentialité](../../docs/legal/privacy-policy.md).

## Documentation

- [Prise en main](../../docs/getting-started.md) — configuration requise, ressources, le Workshop et l’importation
- [Fonctionnalités](../../docs/features.md) — tout ce que l’app prend en charge, et comment l’utiliser
- Guides : [dispositions des moniteurs](../../docs/display-layouts.md) · [playlists](../../docs/playlists.md) · [économiseur d’écran](../../docs/screen-saver.md) · [exportation pour iPhone et iPad](../../docs/iphone-ipad-export.md) · [exportation pour Android](../../docs/android-export.md) · [cartes de profondeur](../../docs/depth-maps.md) · [thèmes](../../docs/theming.md) · [importation de modèles](../../docs/model-import.md) · [outils d’image](../../docs/image-tools.md) · [Serveur MCP](../../docs/mcp.md) · [ligne de commande](../../docs/command-line.md) · [moteur web Chromium](../../docs/chromium-engine.md)
- [Développement](../../docs/development.md) — compilation à partir des sources et organisation du projet ; [CONTRIBUTING.md](../../CONTRIBUTING.md) et [architecture](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — guides, référence des réglages et dépannage

## Projets associés

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — Une interface PyQt6 pour [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), avec intégration du Steam Workshop et un design d’interface repris de cette version macOS.

## Remerciements

Ce projet s’appuie sur le travail de :

- **[MrWindDog](https://github.com/MrWindDog)** — Mainteneur du fork en amont [wallpaper-engine-mac](https://github.com/MrWindDog), a ajouté de nouvelles fonctionnalités et des améliorations de l’interface
- **[Haren Chen](https://github.com/haren724)** — Créateur d’origine d’[open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), a conçu l’architecture de base de l’app (SwiftUI, lecture des fonds d’écran vidéo, système d’importation, interface des playlists)
- **1ris_W** — Traduction chinoise (i18n)
- **[Klaus Zhu](https://github.com/klauszhu1105)** — Conception du logo d’origine
- **[Chen Chia Yang](https://github.com/Unayung)** — Rendu des fonds d’écran de scène, corrections des fonds d’écran web, intégration du Steam Workshop, prise en charge de plusieurs moniteurs, importation de fichiers zip
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Moteur de rendu de scène Metal et pipeline d’effets, traduction et mise en cache des nuanceurs GLSL→MSL, environnement d’exécution SceneScript, rendu réactif au son, refonte du Workshop et des téléchargements, réglages de placement et de performances, refonte du logo

Distribué sous licence [GPL-3.0](../../LICENSE), comme le projet d’origine.

## Mentions légales

[Conditions d’utilisation](../../docs/legal/terms-of-use.md) · [Politique de confidentialité](../../docs/legal/privacy-policy.md) · [Politique de sécurité](../../SECURITY.md)

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
