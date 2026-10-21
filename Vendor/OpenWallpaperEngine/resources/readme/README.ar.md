Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | **العربية** | [हिन्दी](README.hi.md)

<div dir="rtl">

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine تطبيق مجاني ومفتوح المصدر لنظام macOS يشغّل خلفيات Wallpaper Engine ويحرّرها: المشهد والفيديو والويب. تُرسم المشاهد بمحرك عرض أصلي مبني على Metal، مع التأثيرات والجسيمات والنماذج ثلاثية الأبعاد والإضاءة وSceneScript والمؤثرات المرئية المتفاعلة مع الصوت، وورشة Steam مدمجة فيه. بدأ المشروع كنسخة متفرعة (fork) من [Open Wallpaper Engine](https://github.com/MrWindDog) لمطوّريه Haren Chen وMrWindDog، ثم أُعيدت كتابة معظمه منذ ذلك الحين.

> **ملاحظة:** هذا المشروع غير تابع لتطبيق Wallpaper Engine التجاري على Steam. إنه تطبيق مفتوح المصدر لنظام macOS يمكنه عرض ملفات خلفيات الشاشة من ورشة Steam الخاصة بـ Wallpaper Engine. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**الموقع:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **الويكي:** [الأدلة وحل المشكلات](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![المكتبة](../../docs/images/library.jpg)

## ما يميّزه

- **التطبيق الوحيد على macOS الذي يحرّر مشاهد Wallpaper Engine.** يفتح محرر الخلفيات طبقات المشهد وتأثيراته وجسيماته وخطه الزمني ونصوصه البرمجية، ويحفظه كخلفية Wallpaper Engine.
- **التصدير إلى صورة حيّة (Live Photo) وإلى Wallpaper Engine على Android.** يصبح أي مشهد أو فيديو شاشة قفل متحركة لأجهزة iPhone وiPad، أو حزمة لتطبيق Wallpaper Engine على Android.
- **مظللات Wallpaper Engine نفسها، مترجمة.** تُرسم كل طبقة وكل تأثير وكل مادة بمظللات الخلفية الأصلية بعد ترجمتها إلى Metal، بما في ذلك التأثيرات التي كتبها مؤلفو الورشة بأنفسهم.
- **شاشة توقف حيّة بالكامل.** ترسم شاشة التوقف خلفية كل شاشة أثناء تشغيلها، فتبقى الساعات والنصوص البرمجية والأجزاء المتفاعلة مع الصوت في حركة. لا يُسجَّل أي شيء.

## أبرز الميزات

- **خلفيات المشهد والفيديو والويب**: مشاهد بتأثيرات وجسيمات ونماذج ثلاثية الأبعاد وأضواء وخطوط زمنية وSceneScript ومؤثرات مرئية متفاعلة مع الصوت، وإخراج HDR للمشاهد ولفيديوهات HDR10 أو HLG على الشاشات التي يمكنها عرضه. تعمل خلفيات الويب في WebKit أو في محرك Chromium الاختياري، مع خصائص المجلدات الخاصة بها والصوت المباشر ومعلومات «قيد التشغيل الآن».
- **ورشة Steam**: تصفّح بخيارات الفرز وعوامل التصفية الخاصة بـ Wallpaper Engine، ونزّل عبر SteamCMD بحساب Steam الخاص بك، أو استورد مجلدات الخلفيات وملفات zip. تضم علامة التبويب «المثبتة» مجلدات Wallpaper Engine وخيارات الفرز الخاصة به.
- **محرر الخلفيات**: محرر على نهج محرر Wallpaper Engine. أضف الطبقات ورتّبها باستخدام أدوات التحكم المرئية (gizmos)، وأضف التأثيرات مع معاينات، واكتب تأثيراتك الخاصة وحرّرها في محرر المظللات، واستورد نماذج FBX وOBJ، وأنشئ الحركة على خط زمني، واكتب SceneScript، وأنشئ خصائص المستخدم، وحرّر أنظمة الجسيمات وهياكل Puppet Warp، واستخدم أدوات الصور في Wallpaper Engine (فصل الأمامية، وإنشاء ورقة الشخصية، وتوليد خريطة نواظم). يبدأ **خلفية جديدة…** خلفيةً من صورة أو من أحد قوالب Wallpaper Engine. أنت تحرّر مسودة: **حفظ** يطبّقها، و**حفظ كخلفية جديدة** يضيف نسخة منها إلى المكتبة، ولا تتغير ملفات الخلفية نفسها أبدًا.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![محرر الخلفيات](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **تحرير/تصدير المشهد**: غيّر طبقات الخلفية قيد التشغيل وتأثيراتها مباشرةً على سطح المكتب، أو اختر ما تعرضه شاشة التوقف، أو صدّر الخلفية كصورة حيّة (Live Photo) أو كحزمة Android.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![تحرير/تصدير المشهد](../../docs/images/scene-editor-live.jpg)

- **شاشة التوقف وشاشة القفل**: تعرض شاشة التوقف خلفية كل شاشة مباشرةً (*شاشة التوقف مثل الخلفية*) أو خلفيةً تختارها، وتعرض شاشة القفل صورةً منها.

  <!-- demo: screen-saver -->

- **التصدير**: شاشات قفل بصور حيّة لأجهزة iPhone وiPad، تُرسل عبر AirDrop أو تُحفظ في الصور، وحزم Wallpaper Engine لنظام Android، تُرسل إلى الجهاز عبر Wi-Fi باستخدام رمز QR.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![الإرسال عبر Wi-Fi](../../docs/images/send-over-wifi.png)

- **شاشات العرض**: خلفية لكل شاشة، أو خلفية واحدة ممتدة عبر الشاشات أو مكرّرة على كل منها، مع المجموعات والتقسيمات والملفات الشخصية، كما في Wallpaper Engine. يشغّل **تشغيل في نافذة** خلفيةً في نافذة خاصة بها.

  ![شاشات العرض](../../docs/images/displays.png)

- **قوائم التشغيل**: بدّل الخلفيات وفق مؤقّت، أو عند تسجيل الدخول، أو حسب وقت اليوم أو يوم الأسبوع، مع انتقالات Wallpaper Engine.

  ![إعدادات قائمة التشغيل](../../docs/images/playlists.png)

- **التحكم**: اختصارات للإجراءات وقوائم التشغيل والخلفيات والملفات الشخصية للشاشات؛ و[سطر الأوامر](../../docs/command-line.md) `-control` الخاص بـ Wallpaper Engine؛ وإضافة **خادم MCP** التي يعيّن عبرها عملاء MCP الخلفيات وقوائم التشغيل والإعدادات ويحرّرون المشاهد، عبر اتصال محلي لا يستطيع فتحه سوى حسابك.

  ![إضافة خادم MCP](../../docs/images/mcp-plugin.png)

- **الطاقة**: تتوقف الخلفيات مؤقتًا أثناء قفل الشاشة، وتتبع قاعدة *جهاز محمول يعمل بالبطارية* في Wallpaper Engine، ويمكنها الانتقال إلى إعداد جودة أقل ومعدل إطارات أقل عند العمل بالبطارية أو في وضع الطاقة المنخفضة.
- **التلوين**: يتبع شريط القوائم ولون التمييز والأيقونات والمجلدات الملوّنة لونَ الخلفية؛ ويمكن لنوافذ Open Wallpaper Engine نفسها استخدام اللون الدقيق.

  ![التلوين](../../docs/images/theming.png)

كل ما عدا ذلك، مرتّبًا حسب المجال: [docs/features.md](../../docs/features.md).

## التثبيت

1. نزّل أحدث إصدار من [openwallpaperengine.app](https://openwallpaperengine.app/) أو من [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). التطبيق موقَّع وموثَّق من Apple، ويحدّث نفسه تلقائيًا.
2. افتح ملف DMG واسحب **Open Wallpaper Engine** إلى مجلد التطبيقات.

يتطلب **macOS 14.0 (Sonoma) أو أحدث**. تحتاج خلفيات المشهد إلى ملفات Wallpaper Engine من نسختك الخاصة من Wallpaper Engine على Steam؛ أما خلفيات الفيديو والويب فلا تحتاج إليها. تحتاج بعض الميزات إلى إصدار أحدث من macOS أو إلى إذن أو إضافة: راجع [البدء](../../docs/getting-started.md#requirements).

## البدء السريع

1. افتح التطبيق. يضبط مساعد الإعداد اللغة وSteamCMD وتسجيل دخولك إلى Steam وملفات Wallpaper Engine، ويمكنه استيراد مفضلتك ومجلداتك من Wallpaper Engine؛ ويمكن تخطي كل خطوة.
2. ثبّت ملفات Wallpaper Engine (*الإعدادات › الموارد*) إذا كنت تريد خلفيات المشهد. تأتي هذه الملفات من نسختك الخاصة من Wallpaper Engine على Steam؛ أما خلفيات الفيديو والويب فتعمل بدونها.
3. ابحث عن الخلفيات في علامتي التبويب **استكشف** و**الورشة**، أو استورد مجلد خلفية أو ملف zip (*ملف › استيراد خلفية من مجلد…*، ⌘I)، أو أنشئ خلفية باستخدام **إضافة خلفية › خلفية جديدة…**.
4. انقر على خلفية في المكتبة، ثم على **تعيين خلفية الشاشة** في تفاصيلها (أو انقر عليها بزر الماوس الأيمن واختر **تعيين كخلفية للشاشة**). تظهر خصائصها أسفلها.

المزيد: [البدء](../../docs/getting-started.md) و[الويكي](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## الخصوصية

كل ما يحفظه التطبيق يبقى على جهاز Mac الخاص بك، ولا يجمع أي بيانات أو تحليلات. يتصل التطبيق بـ Steam (للورشة والملفات) وبـ openwallpaperengine.app (للتحقق من التحديثات) وبـ GitHub (لتنزيلها)، ولا تُنزَّل الإضافات إلا عند تثبيتها. التفاصيل: [ما يتصل به التطبيق](../../docs/getting-started.md#what-the-app-connects-to) و[سياسة الخصوصية](../../docs/legal/privacy-policy.md).

## التوثيق

- [البدء](../../docs/getting-started.md) — المتطلبات والملفات والورشة والاستيراد
- [الميزات](../../docs/features.md) — كل ما يدعمه التطبيق وكيفية استخدامه
- الأدلة: [تخطيطات الشاشات](../../docs/display-layouts.md) · [قوائم التشغيل](../../docs/playlists.md) · [شاشة التوقف](../../docs/screen-saver.md) · [التصدير إلى iPhone وiPad](../../docs/iphone-ipad-export.md) · [التصدير إلى Android](../../docs/android-export.md) · [خرائط العمق](../../docs/depth-maps.md) · [السمات](../../docs/theming.md) · [استيراد النماذج](../../docs/model-import.md) · [أدوات الصور](../../docs/image-tools.md) · [خادم MCP](../../docs/mcp.md) · [سطر الأوامر](../../docs/command-line.md) · [محرك الويب Chromium](../../docs/chromium-engine.md)
- [التطوير](../../docs/development.md) — البناء من المصدر وبنية المشروع؛ وانظر أيضًا [CONTRIBUTING.md](../../CONTRIBUTING.md) و[البنية المعمارية](../../docs/architecture.md)
- [الويكي](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — الأدلة ومرجع الإعدادات وحل المشكلات

</div>

## مشاريع ذات صلة

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — واجهة رسومية مبنية على PyQt6 لـ [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)، مع تكامل مع ورشة Steam وتصميم واجهة مستوحى من إصدار macOS هذا.

## شكر وتقدير

بُني هذا المشروع على عمل كلٍّ من:

- **[MrWindDog](https://github.com/MrWindDog)** — مشرف النسخة الأصلية [wallpaper-engine-mac](https://github.com/MrWindDog)، وقد أضاف ميزات جديدة وتحسينات على الواجهة
- **[Haren Chen](https://github.com/haren724)** — المُنشئ الأصلي لـ [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac)، وقد بنى البنية الأساسية للتطبيق (SwiftUI، وتشغيل خلفيات الفيديو، ونظام الاستيراد، وواجهة قائمة التشغيل)
- **1ris_W** — الترجمة الصينية
- **[Klaus Zhu](https://github.com/klauszhu1105)** — تصميم الشعار الأصلي
- **[Chen Chia Yang](https://github.com/Unayung)** — عرض خلفيات المشهد، وإصلاحات خلفيات الويب، والتكامل مع ورشة Steam، ودعم شاشات العرض المتعددة، والاستيراد من ملفات zip
- **[Deepratna Awale](https://github.com/deepratna-awale)** — عارض المشاهد المبني على Metal ومسار التأثيرات، وترجمة المظللات من GLSL إلى MSL وتخزينها المؤقت، وبيئة تشغيل SceneScript، والعرض المستجيب للصوت، وإعادة تصميم الورشة والتنزيلات، وإعدادات الموضع والأداء، وإعادة تصميم الشعار

مرخَّص بموجب [GPL-3.0](../../LICENSE)، مثل المشروع الأصلي.

## المعلومات القانونية

[شروط الاستخدام](../../docs/legal/terms-of-use.md) · [سياسة الخصوصية](../../docs/legal/privacy-policy.md) · [سياسة الأمان](../../SECURITY.md)

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
