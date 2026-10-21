Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | **Italiano** | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine è un’app gratuita e open source per macOS che riproduce e modifica gli sfondi di Wallpaper Engine: scena, video e web. Le scene vengono disegnate da un renderer Metal nativo, con effetti, particelle, modelli 3D, illuminazione, SceneScript ed elementi visivi reattivi all’audio, e lo Steam Workshop è integrato. È nata come fork di [Open Wallpaper Engine](https://github.com/MrWindDog) di Haren Chen e MrWindDog ed è stata poi in gran parte riscritta.

> **Nota:** questo progetto NON è affiliato al Wallpaper Engine commerciale venduto su Steam. È un’app open source per macOS in grado di mostrare le risorse degli sfondi dello Steam Workshop di Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Sito web:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki:** [guide e risoluzione dei problemi](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![La libreria](../../docs/images/library.jpg)

## Cosa lo distingue

- **L’unica app per macOS che modifica le scene di Wallpaper Engine.** L’Editor sfondi apre i livelli, gli effetti, le particelle, la timeline e gli script di una scena, e la salva come sfondo di Wallpaper Engine.
- **Esportazione Live Photo e per Wallpaper Engine su Android.** Qualsiasi scena o video diventa una schermata di blocco animata per iPhone e iPad, o un pacchetto per l’app Android di Wallpaper Engine.
- **Gli shader propri di Wallpaper Engine, tradotti.** Ogni livello, effetto e materiale viene disegnato con gli shader originali dello sfondo, tradotti in Metal, compresi gli effetti che gli autori del Workshop hanno scritto da sé.
- **Un salvaschermo completamente dal vivo.** Il salvaschermo disegna lo sfondo di ciascuno schermo mentre è in esecuzione, quindi orologi, script ed elementi reattivi all’audio continuano a muoversi. Non viene registrato nulla.

## In evidenza

- **Sfondi scena, video e web**: scene con effetti, particelle, modelli 3D, luci, timeline, SceneScript ed elementi visivi reattivi all’audio, e uscita HDR per le scene e per i video HDR10 o HLG sugli schermi in grado di mostrarla. Gli sfondi web girano in WebKit o nel motore Chromium opzionale, con le proprietà della loro cartella, l’audio dal vivo e In riproduzione.
- **Steam Workshop**: sfoglia con gli ordinamenti e i filtri di Wallpaper Engine, scarica tramite SteamCMD con il tuo account Steam, oppure importa cartelle e file zip di sfondi. La scheda Installati ha le cartelle e gli ordinamenti di Wallpaper Engine.
- **Editor sfondi**: un editor sul modello di quello di Wallpaper Engine. Aggiungi e disponi i livelli con i gizmo, aggiungi effetti con anteprime, scrivi e modifica i tuoi effetti nell’Editor shader, importa modelli FBX e OBJ, anima su una timeline, scrivi SceneScript, crea proprietà utente, modifica sistemi particellari e rig Puppet Warp, e usa gli strumenti immagine di Wallpaper Engine (Separazione primo piano, Creazione del foglio del personaggio, Generazione mappatura normale). **Nuovo sfondo…** ne crea uno da un’immagine o da uno dei modelli di Wallpaper Engine. Modifichi una bozza: **Salva** la applica, **Salva come nuovo sfondo** ne aggiunge una copia alla libreria, e i file dello sfondo stesso non vengono mai modificati.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Editor sfondi](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Modifica/esporta scena**: modifica dal vivo sulla scrivania i livelli e gli effetti dello sfondo in esecuzione, scegli cosa mostra il salvaschermo o esporta lo sfondo come Live Photo o come pacchetto Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Modifica/esporta scena](../../docs/images/scene-editor-live.jpg)

- **Salvaschermo e schermata di blocco**: il salvaschermo mostra dal vivo lo sfondo di ciascuno schermo (*Salvaschermo uguale allo sfondo*), oppure uno a tua scelta, e la schermata di blocco ne mostra un’immagine.

  <!-- demo: screen-saver -->

- **Esportazione**: schermate di blocco Live Photo per iPhone e iPad, inviate con AirDrop o salvate in Foto, e pacchetti Android di Wallpaper Engine, inviati al dispositivo via Wi-Fi con un codice QR.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Invia via Wi-Fi](../../docs/images/send-over-wifi.png)

- **Schermi**: uno sfondo per schermo, uno solo esteso su tutti o clonato su ciascuno, gruppi, suddivisioni e profili, come in Wallpaper Engine. **Riproduci in una finestra** riproduce uno sfondo in una finestra tutta sua.

  ![Schermi](../../docs/images/displays.png)

- **Playlist**: cambia sfondo con un timer, all’accesso, in base all’ora del giorno o al giorno della settimana, con le transizioni di Wallpaper Engine.

  ![Impostazioni delle playlist](../../docs/images/playlists.png)

- **Controllo**: tasti di scelta rapida per azioni, playlist, sfondi e profili degli schermi; la [riga di comando](../../docs/command-line.md) `-control` di Wallpaper Engine; e il plug-in **Server MCP**, tramite il quale i client MCP impostano sfondi, playlist e impostazioni e modificano le scene, attraverso una connessione locale che solo il tuo account può aprire.

  ![Plug-in Server MCP](../../docs/images/mcp-plugin.png)

- **Alimentazione**: gli sfondi vanno in pausa mentre lo schermo è bloccato, seguono la regola *Portatile a batteria* di Wallpaper Engine e possono passare a un preset di qualità e a una frequenza fotogrammi inferiori a batteria o in modalità Risparmio energetico.
- **Tema colore**: la barra dei menu, il colore di evidenziazione e le icone e le cartelle colorate seguono il colore dello sfondo; le finestre di Open Wallpaper Engine possono usare il colore esatto.

  ![Tema colore](../../docs/images/theming.png)

Tutto il resto, area per area: [docs/features.md](../../docs/features.md).

## Installazione

1. Scarica l’ultima versione da [openwallpaperengine.app](https://openwallpaperengine.app/) o da [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). È firmata e autenticata da Apple, e si aggiorna da sola.
2. Apri il DMG e trascina **Open Wallpaper Engine** in Applicazioni.

Serve **macOS 14.0 (Sonoma) o successivo**. Gli sfondi di tipo scena richiedono le risorse di Wallpaper Engine della tua copia di Wallpaper Engine su Steam; gli sfondi video e web no. Alcune funzionalità richiedono una versione di macOS più recente, un permesso o un plug-in: vedi [Per iniziare](../../docs/getting-started.md#requirements).

## Avvio rapido

1. Apri l’app. L’assistente di configurazione imposta la lingua, SteamCMD, l’accesso a Steam e le risorse di Wallpaper Engine, e può importare i tuoi preferiti e le tue cartelle di Wallpaper Engine; ogni passaggio si può saltare.
2. Installa le risorse di Wallpaper Engine (*Impostazioni › Risorse*) se vuoi gli sfondi di tipo scena. Provengono dalla tua copia di Wallpaper Engine su Steam; gli sfondi video e web funzionano anche senza.
3. Trova sfondi nelle schede **Esplora** e **Workshop**, importa una cartella o un file zip di uno sfondo (*File › Importa sfondo da cartella…*, ⌘I) oppure creane uno con **Aggiungi sfondo › Nuovo sfondo…**.
4. Fai clic su uno sfondo nella libreria, poi su **Imposta sfondo** nei suoi dettagli (oppure fai clic su di esso con il tasto destro e scegli **Imposta come sfondo**). Le sue proprietà sono elencate subito sotto.

Altro: [Per iniziare](../../docs/getting-started.md) e il [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Privacy

Tutto ciò che l’app salva resta sul tuo Mac, e non raccoglie dati né statistiche. Contatta Steam (per il Workshop e le risorse), openwallpaperengine.app (per cercare gli aggiornamenti) e GitHub (per scaricarli), e i plug-in vengono scaricati solo quando li installi. Dettagli: [a cosa si connette l’app](../../docs/getting-started.md#what-the-app-connects-to) e l’[informativa sulla privacy](../../docs/legal/privacy-policy.md).

## Documentazione

- [Per iniziare](../../docs/getting-started.md) — requisiti, risorse, il Workshop e l’importazione
- [Funzionalità](../../docs/features.md) — tutto ciò che l’app supporta e come usarlo
- Guide: [disposizioni degli schermi](../../docs/display-layouts.md) · [playlist](../../docs/playlists.md) · [salvaschermo](../../docs/screen-saver.md) · [esportazione per iPhone e iPad](../../docs/iphone-ipad-export.md) · [esportazione per Android](../../docs/android-export.md) · [mappe di profondità](../../docs/depth-maps.md) · [temi](../../docs/theming.md) · [importazione di modelli](../../docs/model-import.md) · [strumenti immagine](../../docs/image-tools.md) · [Server MCP](../../docs/mcp.md) · [riga di comando](../../docs/command-line.md) · [motore web Chromium](../../docs/chromium-engine.md)
- [Sviluppo](../../docs/development.md) — compilare dal codice sorgente e struttura del progetto; [CONTRIBUTING.md](../../CONTRIBUTING.md) e [architettura](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — guide, riferimento delle impostazioni e risoluzione dei problemi

## Progetti correlati

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — Un’interfaccia grafica PyQt6 per [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), con integrazione dello Steam Workshop e design dell’interfaccia portato da questa versione per macOS.

## Riconoscimenti

Questo progetto si basa sul lavoro di:

- **[MrWindDog](https://github.com/MrWindDog)** — Manutentore del fork upstream [wallpaper-engine-mac](https://github.com/MrWindDog); ha aggiunto nuove funzionalità e perfezionamenti all’interfaccia
- **[Haren Chen](https://github.com/haren724)** — Creatore originale di [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac); ha realizzato l’architettura di base dell’app (SwiftUI, riproduzione degli sfondi video, sistema di importazione, interfaccia delle playlist)
- **1ris_W** — Traduzione in cinese
- **[Klaus Zhu](https://github.com/klauszhu1105)** — Design originale del logo
- **[Chen Chia Yang](https://github.com/Unayung)** — Rendering degli sfondi di tipo scena, correzioni per gli sfondi web, integrazione dello Steam Workshop, supporto per più schermi, importazione di file zip
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Renderer di scene Metal e pipeline degli effetti, traduzione e caching degli shader GLSL→MSL, runtime di SceneScript, rendering reattivo all’audio, revisione di Workshop e Download, impostazioni di posizionamento e prestazioni, riprogettazione del logo

Distribuito con licenza [GPL-3.0](../../LICENSE), come il progetto originale.

## Note legali

[Condizioni d’uso](../../docs/legal/terms-of-use.md) · [Informativa sulla privacy](../../docs/legal/privacy-policy.md) · [Politica di sicurezza](../../SECURITY.md)

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
