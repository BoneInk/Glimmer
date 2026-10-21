Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | **Español** | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine es una app gratuita y de código abierto para macOS que reproduce y edita fondos de pantalla de Wallpaper Engine: de escena, de vídeo y web. Las escenas se dibujan con un renderizador nativo en Metal, con efectos, partículas, modelos 3D, iluminación, SceneScript y visuales que reaccionan al audio, y Steam Workshop está integrado. Nació como un fork de [Open Wallpaper Engine](https://github.com/MrWindDog) de Haren Chen y MrWindDog, y desde entonces se ha reescrito en gran parte.

> **Nota:** Este proyecto NO está afiliado al Wallpaper Engine comercial de Steam. Es una app de código abierto para macOS que puede mostrar recursos de fondos de pantalla del Steam Workshop de Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Sitio web:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki:** [guías y solución de problemas](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![La biblioteca](../../docs/images/library.jpg)

## Qué lo hace diferente

- **La única app de macOS que edita escenas de Wallpaper Engine.** El Editor de fondos de pantalla abre las capas, los efectos, las partículas, la línea de tiempo y los scripts de una escena, y la guarda como fondo de pantalla de Wallpaper Engine.
- **Exportación a Live Photo y a Wallpaper Engine para Android.** Cualquier escena o vídeo se convierte en una pantalla de bloqueo animada para iPhone y iPad, o en un paquete para la app de Android de Wallpaper Engine.
- **Los propios sombreadores de Wallpaper Engine, traducidos.** Cada capa, efecto y material se dibuja con los sombreadores originales del fondo de pantalla, traducidos a Metal, incluidos los efectos que los autores del Workshop escribieron ellos mismos.
- **Un salvapantallas totalmente en vivo.** El salvapantallas dibuja el fondo de pantalla de cada pantalla mientras se ejecuta, así que los relojes, los scripts y las partes que reaccionan al audio siguen moviéndose. No se graba nada.

## Lo más destacado

- **Fondos de pantalla de escena, de vídeo y web**: escenas con efectos, partículas, modelos 3D, luces, líneas de tiempo, SceneScript y visuales que reaccionan al audio, y salida HDR para escenas y vídeos HDR10 o HLG en las pantallas que puedan mostrarla. Los fondos web se ejecutan en WebKit o en el motor Chromium opcional, con las propiedades de su carpeta, audio en vivo y Ahora suena.
- **Steam Workshop**: explora con las ordenaciones y los filtros de Wallpaper Engine, descarga mediante SteamCMD con tu propia cuenta de Steam, o importa carpetas y archivos zip de fondos de pantalla. La pestaña Instalados tiene las carpetas y las ordenaciones de Wallpaper Engine.
- **Editor de fondos de pantalla**: un editor al estilo del de Wallpaper Engine. Añade y coloca capas con gizmos, añade efectos con vista previa, escribe y edita tus propios efectos en el Editor de sombreadores, importa modelos FBX y OBJ, anima en una línea de tiempo, escribe SceneScript, crea propiedades de usuario, edita sistemas de partículas y esqueletos de Puppet Warp, y usa las herramientas de imagen de Wallpaper Engine (Separación del primer plano, Hoja de creación de personaje, Generar mapeado normal). **Nuevo fondo de pantalla…** crea uno a partir de una imagen o de una de las plantillas de Wallpaper Engine. Editas un borrador: **Guardar** lo aplica, **Guardar como nuevo fondo de pantalla** añade una copia a la biblioteca, y los archivos del propio fondo de pantalla nunca se modifican.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Editor de fondos de pantalla](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Editar/exportar escena**: cambia en vivo en el escritorio las capas y los efectos del fondo que se está reproduciendo, elige lo que muestra el salvapantallas o exporta el fondo de pantalla como Live Photo o como paquete de Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Editar/exportar escena](../../docs/images/scene-editor-live.jpg)

- **Salvapantallas y pantalla de bloqueo**: el salvapantallas muestra en vivo el fondo de pantalla de cada pantalla (*Salvapantallas igual que el fondo de pantalla*), u otro que elijas, y la pantalla de bloqueo muestra una imagen de él.

  <!-- demo: screen-saver -->

- **Exportación**: pantallas de bloqueo Live Photo para iPhone y iPad, enviadas con AirDrop o guardadas en Fotos, y paquetes de Android de Wallpaper Engine, enviados al dispositivo por Wi-Fi con un código QR.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Enviar por Wi-Fi](../../docs/images/send-over-wifi.png)

- **Pantallas**: un fondo por pantalla, uno estirado a lo largo de todas o clonado en cada una, grupos, divisiones y perfiles, como en Wallpaper Engine. **Reproducir en ventana** reproduce un fondo de pantalla en una ventana propia.

  ![Pantallas](../../docs/images/displays.png)

- **Playlists**: cambia de fondo con un temporizador, al iniciar sesión, según la hora del día o el día de la semana, con las transiciones de Wallpaper Engine.

  ![Ajustes de playlists](../../docs/images/playlists.png)

- **Control**: teclas de acceso rápido para acciones, playlists, fondos de pantalla y perfiles de pantalla; la [línea de comandos](../../docs/command-line.md) `-control` de Wallpaper Engine; y el complemento **Servidor MCP**, a través del cual los clientes MCP establecen fondos de pantalla, playlists y ajustes y editan escenas, mediante una conexión local que solo tu cuenta puede abrir.

  ![Complemento Servidor MCP](../../docs/images/mcp-plugin.png)

- **Energía**: los fondos de pantalla se pausan mientras la pantalla está bloqueada, siguen la regla *Portátil con batería* de Wallpaper Engine y pueden bajar a un preajuste de calidad y una velocidad de fotogramas inferiores con batería o en modo de bajo consumo.
- **Temas de color**: la barra de menús, el color de acento y los iconos y carpetas teñidos siguen el color del fondo de pantalla; las propias ventanas de Open Wallpaper Engine pueden usar el color exacto.

  ![Temas de color](../../docs/images/theming.png)

Todo lo demás, área por área: [docs/features.md](../../docs/features.md).

## Instalación

1. Descarga la última versión desde [openwallpaperengine.app](https://openwallpaperengine.app/) o [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). Está firmada y notarizada, y se actualiza sola.
2. Abre el DMG y arrastra **Open Wallpaper Engine** a Aplicaciones.

Necesitas **macOS 14.0 (Sonoma) o posterior**. Los fondos de pantalla de escena necesitan los recursos de Wallpaper Engine de tu propia copia de Wallpaper Engine en Steam; los de vídeo y web, no. Algunas funciones requieren una versión más reciente de macOS, un permiso o un complemento: consulta [Primeros pasos](../../docs/getting-started.md#requirements).

## Inicio rápido

1. Abre la app. El asistente de configuración establece el idioma, SteamCMD, tu inicio de sesión de Steam y los recursos de Wallpaper Engine, y puede importar tus favoritos y carpetas de Wallpaper Engine; todos los pasos se pueden omitir.
2. Instala los recursos de Wallpaper Engine (*Ajustes › Recursos*) si quieres fondos de pantalla de escena. Proceden de tu propia copia de Wallpaper Engine en Steam; los fondos de vídeo y web funcionan sin ellos.
3. Busca fondos de pantalla en las pestañas **Descubrir** y **Workshop**, importa una carpeta o un archivo zip de fondo de pantalla (*Archivo › Importar fondo de pantalla desde carpeta…*, ⌘I) o crea uno con **Añadir fondo de pantalla › Nuevo fondo de pantalla…**.
4. Haz clic en un fondo de pantalla de la biblioteca y luego en **Establecer fondo de pantalla** en sus detalles (o haz clic en él con el botón derecho y elige **Usar como fondo de pantalla**). Sus propiedades aparecen debajo.

Más información: [Primeros pasos](../../docs/getting-started.md) y la [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Privacidad

Todo lo que guarda la app se queda en tu Mac, y no recopila datos ni analíticas. Se conecta a Steam (para el Workshop y los recursos), a openwallpaperengine.app (para buscar actualizaciones) y a GitHub (para descargarlas), y los complementos solo se descargan cuando los instalas. Detalles: [a qué se conecta la app](../../docs/getting-started.md#what-the-app-connects-to) y la [política de privacidad](../../docs/legal/privacy-policy.md).

## Documentación

- [Primeros pasos](../../docs/getting-started.md): requisitos, recursos, el Workshop y la importación
- [Funciones](../../docs/features.md): todo lo que admite la app y cómo usarlo
- Guías: [disposiciones de pantallas](../../docs/display-layouts.md) · [playlists](../../docs/playlists.md) · [salvapantallas](../../docs/screen-saver.md) · [exportación a iPhone y iPad](../../docs/iphone-ipad-export.md) · [exportación a Android](../../docs/android-export.md) · [mapas de profundidad](../../docs/depth-maps.md) · [temas](../../docs/theming.md) · [importación de modelos](../../docs/model-import.md) · [herramientas de imagen](../../docs/image-tools.md) · [Servidor MCP](../../docs/mcp.md) · [línea de comandos](../../docs/command-line.md) · [motor web Chromium](../../docs/chromium-engine.md)
- [Desarrollo](../../docs/development.md): compilar desde el código fuente y la estructura del proyecto; [CONTRIBUTING.md](../../CONTRIBUTING.md) y [arquitectura](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki): guías, referencia de ajustes y solución de problemas

## Proyectos relacionados

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)**: una interfaz gráfica PyQt6 para [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), con integración del Steam Workshop y un diseño de interfaz adaptado de esta versión para macOS.

## Créditos

Este proyecto se basa en el trabajo de:

- **[MrWindDog](https://github.com/MrWindDog)**: responsable del fork original [wallpaper-engine-mac](https://github.com/MrWindDog); añadió nuevas funciones y mejoras de la interfaz
- **[Haren Chen](https://github.com/haren724)**: creador original de [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac); desarrolló la arquitectura base de la app (SwiftUI, reproducción de fondos de pantalla de vídeo, sistema de importación, interfaz de playlists)
- **1ris_W**: traducción al chino (i18n)
- **[Klaus Zhu](https://github.com/klauszhu1105)**: diseño original del logotipo
- **[Chen Chia Yang](https://github.com/Unayung)**: renderizado de fondos de pantalla de escena, correcciones de fondos de pantalla web, integración del Steam Workshop, compatibilidad con varias pantallas, importación de archivos zip
- **[Deepratna Awale](https://github.com/deepratna-awale)**: renderizador de escenas Metal y pipeline de efectos, traducción y almacenamiento en caché de sombreadores GLSL→MSL, entorno de ejecución de SceneScript, renderizado que reacciona al audio, renovación del Workshop y las descargas, ajustes de colocación y rendimiento, rediseño del logotipo

Con licencia [GPL-3.0](../../LICENSE), igual que el proyecto original.

## Aviso legal

[Condiciones de uso](../../docs/legal/terms-of-use.md) · [Política de privacidad](../../docs/legal/privacy-policy.md) · [Política de seguridad](../../SECURITY.md)

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
