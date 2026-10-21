Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | **Українська** | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine — безкоштовна програма з відкритим кодом для macOS, яка відтворює й редагує шпалери Wallpaper Engine: сцени, відео та вебшпалери. Сцени малюються власним рендерером на Metal з ефектами, частинками, 3D-моделями, освітленням, SceneScript і візуалізаціями, що реагують на звук, а Майстерню Steam вбудовано в програму. Проєкт починався як форк [Open Wallpaper Engine](https://github.com/MrWindDog) від Харена Чена (Haren Chen) і MrWindDog, а відтоді його здебільшого переписано.

> **Примітка.** Цей проєкт НЕ повʼязаний із комерційною програмою Wallpaper Engine у Steam. Це програма з відкритим кодом для macOS, яка може показувати ресурси шпалер із Майстерні Steam програми Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**Сайт:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Вікі:** [посібники та усунення проблем](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![Бібліотека](../../docs/images/library.jpg)

## Чим вона вирізняється

- **Єдина програма для macOS, яка редагує сцени Wallpaper Engine.** Редактор шпалер відкриває шари, ефекти, частинки, таймлайн і скрипти сцени та зберігає її як шпалеру Wallpaper Engine.
- **Експорт у Live Photo і для Wallpaper Engine на Android.** Будь-яка сцена чи відео стає рухомим екраном блокування для iPhone та iPad або пакетом для Android-застосунку Wallpaper Engine.
- **Власні шейдери Wallpaper Engine, перекладені.** Кожен шар, ефект і матеріал малюється оригінальними шейдерами шпалери, перекладеними на Metal, зокрема й ефекти, які автори з Майстерні написали самі.
- **Повністю жива заставка.** Заставка малює шпалеру кожного дисплея під час її роботи, тож годинники, скрипти й частини, що реагують на звук, продовжують рухатися. Нічого не записується.

## Основні можливості

- **Шпалери-сцени, відео та вебшпалери**: сцени з ефектами, частинками, 3D-моделями, джерелами світла, таймлайнами, SceneScript і візуалізаціями, що реагують на звук, а також виведення HDR для сцен і відео HDR10 чи HLG на дисплеях, які можуть його показати. Вебшпалери працюють у WebKit або в додатковому рушії Chromium, з їхніми властивостями-теками, живим звуком і «Зараз відтворюється».
- **Майстерня Steam**: переглядайте Майстерню із сортуваннями й фільтрами Wallpaper Engine, викачуйте через SteamCMD зі своїм обліковим записом Steam або імпортуйте теки й zip-архіви зі шпалерами. Вкладка «Встановлені» має теки й сортування Wallpaper Engine.
- **Редактор шпалер**: редактор у дусі редактора Wallpaper Engine. Додавайте й розташовуйте шари за допомогою гізмо, додавайте ефекти з попереднім переглядом, пишіть і редагуйте власні ефекти в Редакторі шейдерів, імпортуйте моделі FBX і OBJ, анімуйте на таймлайні, пишіть SceneScript, створюйте властивості користувача, редагуйте системи частинок і риги Puppet Warp та користуйтеся інструментами зображень Wallpaper Engine (Відокремлення переднього плану, Створення аркуша персонажа, Генерація нормальної карти). **Нові шпалери…** створює нову шпалеру із зображення або з одного із шаблонів Wallpaper Engine. Ви редагуєте чернетку: **Зберегти** застосовує її, **Зберегти як нову шпалеру** додає копію до бібліотеки, а власні файли шпалери ніколи не змінюються.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![Редактор шпалер](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Редагування/експорт сцени**: змінюйте шари й ефекти запущеної шпалери просто на робочому столі, вибирайте, що показує заставка, або експортуйте шпалеру як Live Photo чи як пакет для Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![Редагування/експорт сцени](../../docs/images/scene-editor-live.jpg)

- **Заставка й екран блокування**: заставка показує шпалеру кожного дисплея наживо (*Заставка як шпалери*) або вибрану вами шпалеру, а екран блокування показує її зображення.

  <!-- demo: screen-saver -->

- **Експорт**: екрани блокування з Live Photo для iPhone та iPad, які надсилаються через AirDrop або зберігаються у Фото, і пакети для Android-застосунку Wallpaper Engine, які надсилаються на пристрій через Wi-Fi за QR-кодом.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Надсилання через Wi-Fi](../../docs/images/send-over-wifi.png)

- **Дисплеї**: окрема шпалера на кожному дисплеї, одна шпалера, розтягнута на всі дисплеї або продубльована на кожному, а також групи, поділ і профілі — як у Wallpaper Engine. **Відтворити у вікні** відтворює шпалеру в окремому вікні.

  ![Дисплеї](../../docs/images/displays.png)

- **Списки відтворення**: зміна шпалер за таймером, під час входу, залежно від часу доби або дня тижня, з переходами Wallpaper Engine.

  ![Параметри списку відтворення](../../docs/images/playlists.png)

- **Керування**: гарячі клавіші для дій, списків відтворення, шпалер і профілів дисплеїв; [командний рядок](../../docs/command-line.md) `-control` програми Wallpaper Engine; і плагін **Сервер MCP**, через який MCP-клієнти встановлюють шпалери, списки відтворення й параметри та редагують сцени через локальне зʼєднання, відкрити яке може лише ваш обліковий запис.

  ![Плагін MCP-сервера](../../docs/images/mcp-plugin.png)

- **Живлення**: шпалери стають на паузу, поки екран заблоковано, дотримуються правила Wallpaper Engine *Ноутбук від акумулятора* і можуть переходити на нижчий набір якості й нижчу частоту кадрів під час роботи від акумулятора або в режимі низького енергоспоживання.
- **Колірна тема**: смуга меню, колір акценту, тоновані іконки й теки підлаштовуються під колір шпалери; власні вікна Open Wallpaper Engine можуть використовувати точний колір.

  ![Колірна тема](../../docs/images/theming.png)

Усе інше, за розділами: [docs/features.md](../../docs/features.md).

## Встановлення

1. Викачайте останній випуск з [openwallpaperengine.app](https://openwallpaperengine.app/) або з [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). Програма підписана й нотаризована та оновлюється самостійно.
2. Відкрийте DMG і перетягніть **Open Wallpaper Engine** до теки «Програми».

Потрібна **macOS 14.0 (Sonoma) або новіша**. Для шпалер-сцен потрібні ресурси Wallpaper Engine з вашої власної копії Wallpaper Engine у Steam; для відео- та вебшпалер — ні. Для деяких функцій потрібні новіша macOS, окремий дозвіл або плагін: див. [Початок роботи](../../docs/getting-started.md#requirements).

## Швидкий старт

1. Відкрийте програму. Асистент налаштування задасть мову, SteamCMD, вхід у Steam і ресурси Wallpaper Engine, а також може імпортувати ваші улюблені й теки з Wallpaper Engine; будь-який крок можна пропустити.
2. Якщо вам потрібні шпалери-сцени, встановіть ресурси Wallpaper Engine (*Параметри › Ресурси*). Вони беруться з вашої власної копії Wallpaper Engine у Steam; відео- та вебшпалери працюють і без них.
3. Шукайте шпалери на вкладках **Огляд** і **Майстерня**, імпортуйте теку чи zip-архів зі шпалерою (*Файл › Імпортувати шпалери з папки…*, ⌘I) або створіть шпалеру командою **Додати шпалеру › Нові шпалери…**.
4. Клацніть шпалеру в бібліотеці, а потім — **Встановити шпалеру** в її деталях (або клацніть її правою кнопкою й виберіть **Зробити шпалерою**). Її властивості наведено нижче.

Докладніше: [Початок роботи](../../docs/getting-started.md) і [вікі](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Конфіденційність

Усе, що зберігає програма, залишається на вашому Mac, і вона не збирає жодних даних чи аналітики. Програма звертається до Steam (для Майстерні й ресурсів), до openwallpaperengine.app (щоб перевіряти оновлення) і до GitHub (щоб їх викачувати), а плагіни викачуються лише тоді, коли ви їх встановлюєте. Докладніше: [до чого підключається програма](../../docs/getting-started.md#what-the-app-connects-to) і [Політика конфіденційності](../../docs/legal/privacy-policy.md).

## Документація

- [Початок роботи](../../docs/getting-started.md) — вимоги, ресурси, Майстерня та імпорт
- [Можливості](../../docs/features.md) — усе, що підтримує програма, і як цим користуватися
- Посібники: [розкладки дисплеїв](../../docs/display-layouts.md) · [списки відтворення](../../docs/playlists.md) · [заставка](../../docs/screen-saver.md) · [експорт для iPhone та iPad](../../docs/iphone-ipad-export.md) · [експорт для Android](../../docs/android-export.md) · [карти глибини](../../docs/depth-maps.md) · [оформлення](../../docs/theming.md) · [імпорт моделей](../../docs/model-import.md) · [інструменти зображень](../../docs/image-tools.md) · [MCP-сервер](../../docs/mcp.md) · [командний рядок](../../docs/command-line.md) · [вебрушій Chromium](../../docs/chromium-engine.md)
- [Розробка](../../docs/development.md) — збирання з вихідного коду та структура проєкту; див. також [CONTRIBUTING.md](../../CONTRIBUTING.md) і [архітектуру](../../docs/architecture.md)
- [Вікі](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — посібники, довідник параметрів і усунення проблем

## Повʼязані проєкти

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — графічний інтерфейс на PyQt6 для [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) з інтеграцією Майстерні Steam і дизайном інтерфейсу, перенесеним із цієї версії для macOS.

## Подяки

Цей проєкт створено на основі роботи таких людей:

- **[MrWindDog](https://github.com/MrWindDog)** — супровідник висхідного форка [wallpaper-engine-mac](https://github.com/MrWindDog); додав нові функції та вдосконалив інтерфейс
- **[Haren Chen](https://github.com/haren724)** — автор оригінального [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac); створив базову архітектуру програми (SwiftUI, відтворення відеошпалер, система імпорту, інтерфейс списків відтворення)
- **1ris_W** — переклад китайською
- **[Klaus Zhu](https://github.com/klauszhu1105)** — оригінальний дизайн логотипа
- **[Chen Chia Yang](https://github.com/Unayung)** — рендеринг шпалер-сцен, виправлення вебшпалер, інтеграція Майстерні Steam, підтримка кількох дисплеїв, імпорт zip-архівів
- **[Deepratna Awale](https://github.com/deepratna-awale)** — рендерер сцен і конвеєр ефектів на Metal, трансляція шейдерів GLSL→MSL та їх кешування, середовище виконання SceneScript, рендеринг, що реагує на звук, оновлення Майстерні та викачування, параметри розміщення й продуктивності, редизайн логотипа

Поширюється за ліцензією [GPL-3.0](../../LICENSE), як і оригінальний проєкт.

## Правова інформація

[Умови використання](../../docs/legal/terms-of-use.md) · [Політика конфіденційності](../../docs/legal/privacy-policy.md) · [Політика безпеки](../../SECURITY.md)

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
