Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | **Русский** | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine — бесплатное приложение с открытым исходным кодом для macOS, которое воспроизводит и редактирует обои Wallpaper Engine: сцены, видео и веб-обои. Сцены отрисовываются нативным рендерером на Metal с эффектами, частицами, 3D-моделями, освещением, SceneScript и визуализациями, реагирующими на звук, а Мастерская Steam встроена в приложение. Проект начинался как форк [Open Wallpaper Engine](https://github.com/MrWindDog) Харена Чена (Haren Chen) и MrWindDog и с тех пор был в основном переписан.

> **Примечание.** Этот проект НЕ связан с коммерческим Wallpaper Engine в Steam. Это приложение для macOS с открытым исходным кодом, которое умеет показывать ресурсы обоев из Мастерской Steam для Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Сайт:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Вики:** [руководства и решение проблем](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![Медиатека](../../docs/images/library.jpg)

## Чем оно выделяется

- **Единственное приложение для macOS, которое редактирует сцены Wallpaper Engine.** Редактор обоев открывает слои, эффекты, частицы, таймлайн и скрипты сцены и сохраняет её как обои Wallpaper Engine.
- **Экспорт в Live Photo и для Android-приложения Wallpaper Engine.** Любая сцена или видео становится движущимся экраном блокировки для iPhone и iPad или пакетом для Android-приложения Wallpaper Engine.
- **Собственные шейдеры Wallpaper Engine в переводе.** Каждый слой, эффект и материал отрисовывается оригинальными шейдерами обоев, переведёнными на Metal, включая эффекты, которые авторы Мастерской написали сами.
- **Полностью живая заставка.** Заставка отрисовывает обои каждого дисплея в реальном времени, поэтому часы, скрипты и элементы, реагирующие на звук, продолжают двигаться. Ничего не записывается.

## Основные возможности

- **Обои-сцены, видео и веб-обои**: сцены с эффектами, частицами, 3D-моделями, источниками света, таймлайнами, SceneScript и визуализациями, реагирующими на звук, а также вывод HDR для сцен и видео HDR10 или HLG на дисплеях, которые могут его показать. Веб-обои работают в WebKit или в дополнительном движке Chromium со свойствами своей папки, живым звуком и Now Playing.
- **Мастерская Steam**: просматривайте обои с сортировками и фильтрами Wallpaper Engine, скачивайте их через SteamCMD под своей учётной записью Steam или импортируйте папки и zip-архивы с обоями. На вкладке «Установленные» есть папки и сортировки Wallpaper Engine.
- **Редактор обоев**: редактор в духе редактора Wallpaper Engine. Добавляйте и располагайте слои с помощью гизмо, добавляйте эффекты с предпросмотром, пишите и правьте собственные эффекты в Редакторе шейдеров, импортируйте модели FBX и OBJ, анимируйте на таймлайне, пишите SceneScript, создавайте пользовательские свойства, редактируйте системы частиц и риги Puppet Warp и пользуйтесь инструментами Wallpaper Engine для изображений («Отделение переднего плана», «Создание страницы персонажа», «Создание карты нормалей»). **Новые обои…** создают обои из изображения или одного из шаблонов Wallpaper Engine. Вы правите черновик: **Сохранить** применяет его, **Сохранить как новые обои** добавляет копию в медиатеку, а собственные файлы обоев никогда не меняются.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Редактор обоев](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Правка/экспорт сцены**: меняйте слои и эффекты запущенных обоев прямо на рабочем столе, выбирайте, что показывает заставка, или экспортируйте обои как Live Photo либо как пакет для Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Правка/экспорт сцены](../../docs/images/scene-editor-live.jpg)

- **Заставка и экран блокировки**: заставка показывает обои каждого дисплея вживую (*Заставка как обои*) или выбранные вами обои, а экран блокировки показывает их изображение.

  <!-- demo: screen-saver -->

- **Экспорт**: экраны блокировки с Live Photo для iPhone и iPad, которые отправляются через AirDrop или сохраняются в «Фото», и пакеты для Android-приложения Wallpaper Engine, которые отправляются на устройство по Wi-Fi через QR-код.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Отправка по Wi-Fi](../../docs/images/send-over-wifi.png)

- **Дисплеи**: свои обои на каждом дисплее, одни обои, растянутые на все дисплеи или продублированные на каждом, а также группы, разделение и профили — как в Wallpaper Engine. **Воспроизвести в окне** воспроизводит обои в отдельном окне.

  ![Дисплеи](../../docs/images/displays.png)

- **Плейлисты**: смена обоев по таймеру, при входе в систему, по времени суток или дню недели, с переходами Wallpaper Engine.

  ![Настройки плейлиста](../../docs/images/playlists.png)

- **Управление**: горячие клавиши для действий, плейлистов, обоев и профилей дисплеев; [командная строка](../../docs/command-line.md) `-control` из Wallpaper Engine; и плагин **Сервер MCP**, через который MCP-клиенты устанавливают обои, плейлисты и настройки и редактируют сцены по локальному подключению, открыть которое может только ваша учётная запись.

  ![Плагин MCP-сервера](../../docs/images/mcp-plugin.png)

- **Питание**: обои ставятся на паузу, пока экран заблокирован, следуют правилу Wallpaper Engine *Ноутбук от аккумулятора* и могут переходить на более низкий пресет качества и частоту кадров при работе от аккумулятора или в режиме энергосбережения.
- **Цветовая тема**: строка меню, акцентный цвет, тонированные значки и папки подстраиваются под цвет обоев; собственные окна Open Wallpaper Engine могут использовать точный цвет.

  ![Цветовая тема](../../docs/images/theming.png)

Всё остальное, по разделам: [docs/features.md](../../docs/features.md).

## Установка

1. Скачайте последний выпуск с [openwallpaperengine.app](https://openwallpaperengine.app/) или из [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). Приложение подписано и нотариально заверено и обновляется само.
2. Откройте DMG и перетащите **Open Wallpaper Engine** в папку «Программы».

Нужна **macOS 14.0 (Sonoma) или новее**. Для обоев-сцен нужны ресурсы Wallpaper Engine из вашей собственной копии Wallpaper Engine в Steam; видео- и веб-обоям они не нужны. Для некоторых функций требуется более новая macOS, отдельное разрешение или плагин: см. [Начало работы](../../docs/getting-started.md#requirements).

## Быстрый старт

1. Откройте приложение. Ассистент настройки задаст язык, SteamCMD, вход в Steam и ресурсы Wallpaper Engine, а также может импортировать ваше избранное и папки из Wallpaper Engine; любой шаг можно пропустить.
2. Если вам нужны обои-сцены, установите ресурсы Wallpaper Engine (*Настройки › Ресурсы*). Они берутся из вашей собственной копии Wallpaper Engine в Steam; видео- и веб-обои работают и без них.
3. Ищите обои на вкладках **Рекомендации** и **Мастерская**, импортируйте папку или zip-архив с обоями (*Файл › Импортировать обои из папки…*, ⌘I) или создайте обои через **Добавить обои › Новые обои…**.
4. Нажмите на обои в медиатеке, а затем — **Установить обои** в их сведениях (или нажмите на них правой кнопкой мыши и выберите **Сделать обоями**). Свойства обоев перечислены ниже.

Подробнее: [Начало работы](../../docs/getting-started.md) и [вики](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Конфиденциальность

Всё, что сохраняет приложение, остаётся на вашем Mac, и оно не собирает никаких данных или аналитики. Приложение обращается к Steam (для Мастерской и ресурсов), к openwallpaperengine.app (чтобы проверить обновления) и к GitHub (чтобы их скачать), а плагины скачиваются только тогда, когда вы их устанавливаете. Подробнее: [к чему подключается приложение](../../docs/getting-started.md#what-the-app-connects-to) и [Политика конфиденциальности](../../docs/legal/privacy-policy.md).

## Документация

- [Начало работы](../../docs/getting-started.md) — требования, ресурсы, Мастерская и импорт
- [Возможности](../../docs/features.md) — всё, что поддерживает приложение, и как этим пользоваться
- Руководства: [раскладки дисплеев](../../docs/display-layouts.md) · [плейлисты](../../docs/playlists.md) · [заставка](../../docs/screen-saver.md) · [экспорт для iPhone и iPad](../../docs/iphone-ipad-export.md) · [экспорт для Android](../../docs/android-export.md) · [карты глубины](../../docs/depth-maps.md) · [оформление](../../docs/theming.md) · [импорт моделей](../../docs/model-import.md) · [инструменты для изображений](../../docs/image-tools.md) · [MCP-сервер](../../docs/mcp.md) · [командная строка](../../docs/command-line.md) · [веб-движок Chromium](../../docs/chromium-engine.md)
- [Разработка](../../docs/development.md) — сборка из исходного кода и структура проекта; см. также [CONTRIBUTING.md](../../CONTRIBUTING.md) и [архитектуру](../../docs/architecture.md)
- [Вики](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — руководства, справочник по настройкам и решение проблем

## Связанные проекты

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — графический интерфейс на PyQt6 для [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) с интеграцией Мастерской Steam и дизайном интерфейса, перенесённым из этой версии для macOS.

## Благодарности

Этот проект основан на работе следующих людей:

- **[MrWindDog](https://github.com/MrWindDog)** — сопровождающий вышестоящего форка [wallpaper-engine-mac](https://github.com/MrWindDog), добавил новые функции и улучшения интерфейса
- **[Haren Chen](https://github.com/haren724)** — автор оригинального [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), создал базовую архитектуру приложения (SwiftUI, воспроизведение видеообоев, система импорта, интерфейс плейлистов)
- **1ris_W** — перевод на китайский язык
- **[Klaus Zhu](https://github.com/klauszhu1105)** — оригинальный дизайн логотипа
- **[Chen Chia Yang](https://github.com/Unayung)** — рендеринг обоев типа «Сцена», исправления веб-обоев, интеграция Мастерской Steam, поддержка нескольких дисплеев, импорт zip-архивов
- **[Deepratna Awale](https://github.com/deepratna-awale)** — рендерер сцен на Metal и конвейер эффектов, трансляция шейдеров GLSL→MSL и их кэширование, среда выполнения SceneScript, рендеринг, реагирующий на звук, переработка Мастерской и загрузок, настройки размещения и производительности, редизайн логотипа

Распространяется по лицензии [GPL-3.0](../../LICENSE), как и исходный проект.

## Правовая информация

[Условия использования](../../docs/legal/terms-of-use.md) · [Политика конфиденциальности](../../docs/legal/privacy-policy.md) · [Политика безопасности](../../SECURITY.md)

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
