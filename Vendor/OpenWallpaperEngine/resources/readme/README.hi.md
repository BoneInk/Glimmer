Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | **हिन्दी**

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine, Wallpaper Engine वॉलपेपर (सीन, वीडियो और वेब) चलाने और एडिट करने वाला एक मुफ़्त, ओपन-सोर्स macOS ऐप है. सीन नेटिव Metal रेंडरर से ड्रॉ होते हैं, जिनमें इफ़ेक्ट, पार्टिकल, 3D मॉडल, लाइटिंग, SceneScript और ऑडियो पर प्रतिक्रिया देने वाले विज़ुअल शामिल हैं, और Steam Workshop ऐप में ही बना हुआ है. इसकी शुरुआत Haren Chen और MrWindDog के [Open Wallpaper Engine](https://github.com/MrWindDog) के fork के रूप में हुई थी, और तब से इसका ज़्यादातर हिस्सा दोबारा लिखा जा चुका है.

> **नोट:** यह Steam पर उपलब्ध कमर्शियल Wallpaper Engine से संबद्ध नहीं है. यह एक ओपन-सोर्स macOS ऐप है, जो Wallpaper Engine के Steam Workshop के वॉलपेपर एसेट दिखा सकता है. → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**वेबसाइट:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **विकी:** [गाइड और समस्या निवारण](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![लाइब्रेरी](../../docs/images/library.jpg)

## इसे क्या अलग बनाता है

- **Wallpaper Engine सीन एडिट करने वाला इकलौता macOS ऐप.** वॉलपेपर एडिटर किसी सीन की लेयर, इफ़ेक्ट, पार्टिकल, टाइमलाइन और स्क्रिप्ट खोलता है, और उसे Wallpaper Engine वॉलपेपर के रूप में सहेजता है.
- **Live Photo और Wallpaper Engine Android एक्सपोर्ट.** कोई भी सीन या वीडियो iPhone और iPad के लिए चलती-फिरती लॉक स्क्रीन बन जाता है, या Wallpaper Engine के Android ऐप के लिए एक पैकेज.
- **Wallpaper Engine के अपने शेडर, ट्रांसलेट किए हुए.** हर लेयर, इफ़ेक्ट और मटीरियल वॉलपेपर के मूल शेडर से ड्रॉ होता है, जिन्हें Metal में बदला जाता है; इनमें वे इफ़ेक्ट भी शामिल हैं जिन्हें Workshop के लेखकों ने ख़ुद लिखा है.
- **पूरी तरह लाइव स्क्रीन सेवर.** स्क्रीन सेवर हर डिस्प्ले का वॉलपेपर चलते हुए ड्रॉ करता है, इसलिए घड़ियाँ, स्क्रिप्ट और ऑडियो पर प्रतिक्रिया देने वाले हिस्से चलते रहते हैं. कुछ भी रिकॉर्ड नहीं किया जाता.

## ख़ास बातें

- **सीन, वीडियो और वेब वॉलपेपर**: इफ़ेक्ट, पार्टिकल, 3D मॉडल, लाइट, टाइमलाइन, SceneScript और ऑडियो पर प्रतिक्रिया देने वाले विज़ुअल वाले सीन, और जो डिस्प्ले इसे दिखा सकते हैं उन पर सीन और HDR10 या HLG वीडियो के लिए HDR आउटपुट. वेब वॉलपेपर WebKit में या वैकल्पिक Chromium इंजन में चलते हैं, अपनी फ़ोल्डर प्रॉपर्टी, लाइव ऑडियो और Now Playing (अभी चल रहा मीडिया) के साथ.
- **Steam Workshop**: Wallpaper Engine के सॉर्ट और फ़िल्टर के साथ ब्राउज़ करें, अपने Steam अकाउंट से SteamCMD के ज़रिए डाउनलोड करें, या वॉलपेपर फ़ोल्डर और zip इंपोर्ट करें. इंस्टॉल किए गए टैब में Wallpaper Engine के फ़ोल्डर और सॉर्ट हैं.
- **वॉलपेपर एडिटर**: Wallpaper Engine के एडिटर की तर्ज़ पर बना एडिटर. गिज़्मो से लेयर जोड़ें और व्यवस्थित करें, प्रीव्यू के साथ इफ़ेक्ट जोड़ें, शेडर एडिटर में अपने इफ़ेक्ट लिखें और एडिट करें, FBX और OBJ मॉडल इंपोर्ट करें, टाइमलाइन पर एनिमेट करें, SceneScript लिखें, यूज़र प्रॉपर्टी बनाएँ, पार्टिकल सिस्टम और Puppet Warp रिग एडिट करें, और Wallpaper Engine के इमेज टूल इस्तेमाल करें (फ़ोरग्राउंड सेपरेशन, कैरेक्टर शीट क्रिएशन, नॉर्मल मैप जनरेशन). **नया वॉलपेपर…** किसी तस्वीर से या Wallpaper Engine के किसी टेम्पलेट से नया वॉलपेपर शुरू करता है. आप एक ड्राफ़्ट एडिट करते हैं: **सहेजें** उसे लागू करता है, **नए वॉलपेपर के रूप में सहेजें** लाइब्रेरी में एक कॉपी जोड़ता है, और वॉलपेपर की अपनी फ़ाइलें कभी नहीं बदलतीं.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![वॉलपेपर एडिटर](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **सीन एडिट/एक्सपोर्ट**: चल रहे वॉलपेपर की लेयर और इफ़ेक्ट सीधे डेस्कटॉप पर लाइव बदलें, चुनें कि स्क्रीन सेवर क्या दिखाए, या वॉलपेपर को Live Photo या Android पैकेज के रूप में एक्सपोर्ट करें.

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![सीन एडिट/एक्सपोर्ट](../../docs/images/scene-editor-live.jpg)

- **स्क्रीन सेवर और लॉक स्क्रीन**: स्क्रीन सेवर हर डिस्प्ले का वॉलपेपर लाइव दिखाता है (*स्क्रीन सेवर वॉलपेपर जैसा ही*), या आपका चुना हुआ कोई वॉलपेपर, और लॉक स्क्रीन उसकी एक तस्वीर दिखाती है.

  <!-- demo: screen-saver -->

- **एक्सपोर्ट**: iPhone और iPad के लिए Live Photo लॉक स्क्रीन, जो AirDrop से भेजी जाती हैं या फ़ोटो में सहेजी जाती हैं, और Wallpaper Engine के Android पैकेज, जो QR कोड के ज़रिए Wi-Fi पर डिवाइस में भेजे जाते हैं.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![Wi-Fi पर भेजें](../../docs/images/send-over-wifi.png)

- **डिस्प्ले**: हर डिस्प्ले पर अलग वॉलपेपर, एक वॉलपेपर सभी डिस्प्ले पर फैला हुआ या हर डिस्प्ले पर क्लोन किया हुआ, साथ ही ग्रुप, स्प्लिट और प्रोफ़ाइल — बिल्कुल Wallpaper Engine की तरह. **विंडो में चलाएँ** किसी वॉलपेपर को उसकी अपनी विंडो में चलाता है.

  ![डिस्प्ले](../../docs/images/displays.png)

- **प्लेलिस्ट**: टाइमर पर, लॉगिन पर, दिन के समय या हफ़्ते के दिन के हिसाब से वॉलपेपर बदलें, Wallpaper Engine के ट्रांज़िशन के साथ.

  ![प्लेलिस्ट सेटिंग](../../docs/images/playlists.png)

- **कंट्रोल**: ऐक्शन, प्लेलिस्ट, वॉलपेपर और डिस्प्ले प्रोफ़ाइल के लिए हॉटकी; Wallpaper Engine की `-control` [कमांड लाइन](../../docs/command-line.md); और **MCP सर्वर** प्लग-इन, जिसके ज़रिए MCP क्लाइंट वॉलपेपर, प्लेलिस्ट और सेटिंग सेट करते हैं और सीन एडिट करते हैं, एक लोकल कनेक्शन पर जिसे सिर्फ़ आपका अकाउंट खोल सकता है.

  ![MCP सर्वर प्लग-इन](../../docs/images/mcp-plugin.png)

- **पावर**: स्क्रीन लॉक रहने पर वॉलपेपर रुक जाते हैं, Wallpaper Engine के *लैपटॉप बैटरी पर हो तब* नियम का पालन करते हैं, और बैटरी पर या लो पावर मोड में कम क्वालिटी प्रीसेट और कम फ़्रेम रेट पर जा सकते हैं.
- **थीमिंग**: मेन्यू बार, एक्सेंट कलर और टिंट किए गए आइकन और फ़ोल्डर वॉलपेपर के रंग के हिसाब से बदलते हैं; Open Wallpaper Engine की अपनी विंडो ठीक वही रंग इस्तेमाल कर सकती हैं.

  ![थीमिंग](../../docs/images/theming.png)

बाकी सब कुछ, हिस्से के हिसाब से: [docs/features.md](../../docs/features.md).

## इंस्टॉल करें

1. नया रिलीज़ [openwallpaperengine.app](https://openwallpaperengine.app/) या [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases) से डाउनलोड करें. यह साइन और नोटराइज़ किया हुआ है, और ख़ुद को अपने-आप अपडेट करता है.
2. DMG खोलें और **Open Wallpaper Engine** को Applications में ड्रैग करें.

आपको **macOS 14.0 (Sonoma) या उसके बाद का वर्ज़न** चाहिए. सीन वॉलपेपर के लिए Steam पर Wallpaper Engine की आपकी अपनी कॉपी से Wallpaper Engine एसेट चाहिए; वीडियो और वेब वॉलपेपर के लिए नहीं. कुछ फ़ीचर के लिए नया macOS, कोई अनुमति या कोई प्लग-इन चाहिए: देखें [शुरुआत करें](../../docs/getting-started.md#requirements).

## जल्दी शुरुआत

1. ऐप खोलें. सेटअप असिस्टेंट भाषा, SteamCMD, आपका Steam लॉगिन और Wallpaper Engine एसेट सेट करता है, और आपके Wallpaper Engine पसंदीदा और फ़ोल्डर इंपोर्ट कर सकता है; हर चरण छोड़ा जा सकता है.
2. अगर आप सीन वॉलपेपर चाहते हैं, तो Wallpaper Engine एसेट इंस्टॉल करें (*सेटिंग › ऐसेट*). ये Steam पर Wallpaper Engine की आपकी अपनी कॉपी से आते हैं; वीडियो और वेब वॉलपेपर इनके बिना भी चलते हैं.
3. **खोजें** और **Workshop** टैब में वॉलपेपर ढूँढें, कोई वॉलपेपर फ़ोल्डर या zip इंपोर्ट करें (*फ़ाइल › फ़ोल्डर से वॉलपेपर इंपोर्ट करें…*, ⌘I), या **वॉलपेपर जोड़ें › नया वॉलपेपर…** से नया वॉलपेपर बनाएँ.
4. लाइब्रेरी में किसी वॉलपेपर पर क्लिक करें, फिर उसके विवरण में **वॉलपेपर सेट करें** पर क्लिक करें (या उस पर राइट-क्लिक करके **वॉलपेपर बनाएँ** चुनें). उसकी प्रॉपर्टी उसके नीचे दिखती हैं.

और जानकारी: [शुरुआत करें](../../docs/getting-started.md) और [विकी](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## निजता

ऐप जो कुछ भी सेव करता है, वह आपके Mac पर ही रहता है, और यह कोई डेटा या एनालिटिक्स इकट्ठा नहीं करता. यह Steam (Workshop और एसेट के लिए), openwallpaperengine.app (अपडेट जाँचने के लिए) और GitHub (उन्हें डाउनलोड करने के लिए) से संपर्क करता है, और प्लग-इन सिर्फ़ तभी डाउनलोड होते हैं जब आप उन्हें इंस्टॉल करते हैं. विवरण: [ऐप किन चीज़ों से कनेक्ट होता है](../../docs/getting-started.md#what-the-app-connects-to) और [गोपनीयता नीति](../../docs/legal/privacy-policy.md).

## डॉक्यूमेंटेशन

- [शुरुआत करें](../../docs/getting-started.md) — ज़रूरी चीज़ें, एसेट, Workshop और इंपोर्ट
- [फ़ीचर](../../docs/features.md) — ऐप जो कुछ भी सपोर्ट करता है, और उसे कैसे इस्तेमाल करें
- गाइड: [डिस्प्ले लेआउट](../../docs/display-layouts.md) · [प्लेलिस्ट](../../docs/playlists.md) · [स्क्रीन सेवर](../../docs/screen-saver.md) · [iPhone और iPad एक्सपोर्ट](../../docs/iphone-ipad-export.md) · [Android एक्सपोर्ट](../../docs/android-export.md) · [डेप्थ मैप](../../docs/depth-maps.md) · [थीमिंग](../../docs/theming.md) · [मॉडल इंपोर्ट](../../docs/model-import.md) · [इमेज टूल](../../docs/image-tools.md) · [MCP सर्वर](../../docs/mcp.md) · [कमांड लाइन](../../docs/command-line.md) · [Chromium वेब इंजन](../../docs/chromium-engine.md)
- [डेवलपमेंट](../../docs/development.md) — सोर्स से बिल्ड करना और प्रोजेक्ट लेआउट; साथ ही [CONTRIBUTING.md](../../CONTRIBUTING.md) और [आर्किटेक्चर](../../docs/architecture.md)
- [विकी](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — गाइड, सेटिंग रेफ़रेंस और समस्या निवारण

## संबंधित प्रोजेक्ट

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) के लिए एक PyQt6 GUI, जिसमें Steam Workshop इंटीग्रेशन है और जिसका UI डिज़ाइन इसी macOS वर्ज़न से लिया गया है.

## आभार

यह प्रोजेक्ट इनके काम पर आधारित है:

- **[MrWindDog](https://github.com/MrWindDog)** — अपस्ट्रीम [wallpaper-engine-mac](https://github.com/MrWindDog) fork के मेंटेनर, जिन्होंने नए फ़ीचर और UI सुधार जोड़े
- **[Haren Chen](https://github.com/haren724)** — [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac) के मूल निर्माता, जिन्होंने ऐप का मुख्य आर्किटेक्चर बनाया (SwiftUI, वीडियो वॉलपेपर प्लेबैक, इंपोर्ट सिस्टम, प्लेलिस्ट UI)
- **1ris_W** — चीनी अनुवाद
- **[Klaus Zhu](https://github.com/klauszhu1105)** — मूल लोगो डिज़ाइन
- **[Chen Chia Yang](https://github.com/Unayung)** — सीन वॉलपेपर रेंडरिंग, वेब वॉलपेपर के सुधार, Steam Workshop इंटीग्रेशन, एक से ज़्यादा डिस्प्ले का सपोर्ट, zip इंपोर्ट
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Metal सीन रेंडरर और इफ़ेक्ट पाइपलाइन, GLSL→MSL शेडर ट्रांसलेशन और कैशिंग, SceneScript रनटाइम, ऑडियो पर प्रतिक्रिया देने वाली रेंडरिंग, Workshop/डाउनलोड का नया रूप, प्लेसमेंट और परफ़ॉर्मेंस सेटिंग, लोगो रीडिज़ाइन

मूल प्रोजेक्ट की तरह, [GPL-3.0](../../LICENSE) के तहत लाइसेंस प्राप्त.

## कानूनी जानकारी

[उपयोग की शर्तें](../../docs/legal/terms-of-use.md) · [गोपनीयता नीति](../../docs/legal/privacy-policy.md) · [सुरक्षा नीति](../../SECURITY.md)

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
