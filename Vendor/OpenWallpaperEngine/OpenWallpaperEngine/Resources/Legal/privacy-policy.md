# Open Wallpaper Engine — Privacy Policy

**Version 1.1 · Effective date: 2026-10-06**

---

> **In short**
>
> Open Wallpaper Engine ("OWE") runs entirely on your Mac. We have no servers, no accounts, no analytics, no crash reporting, no advertising and no tracking. We do not collect, receive, sell or share any personal data. The only things the app sends over the internet go to Valve (Steam), to GitHub (for app updates), to the hosts of the optional plugins you choose to install, and to whatever websites a web wallpaper you install chooses to load. Those services have their own privacy policies.
>
> This summary is for convenience only. The full text below is what applies.

---

## 1. Who is responsible

Open Wallpaper Engine is a free, open-source macOS application released and maintained by **Deepratna Awale**, an individual ("we", "us"). It is based on the open-source Open Wallpaper Engine by Haren Chen and MrWindDog.

- Source code: https://github.com/deepratna-awale/open-wallpaper-engine-mac
- Website: https://openwallpaperengine.app/
- Contact: open an issue at https://github.com/deepratna-awale/open-wallpaper-engine-mac/issues

OWE is not affiliated with, endorsed by or connected to Wallpaper Engine, its developer (Kristjan Skutta / Wallpaper Engine Team), Valve Corporation or Steam.

## 2. What we do not collect

We want to be direct about this, because it is the most important part of this policy:

- We operate **no servers** of our own. The app never contacts us.
- There are **no accounts** with us. You never register or sign in with us.
- There is **no analytics, telemetry, usage tracking or crash reporting**.
- There is **no advertising** and no advertising identifiers.
- We **do not sell, rent, share or disclose** personal data to anyone, because we never receive it.
- We do not use cookies, fingerprinting or similar technologies.

Because nothing reaches us, we cannot see how you use the app, what wallpapers you have, or who you are.

## 3. What stays on your Mac

OWE stores the following **only on your Mac**, under your control. None of it is sent to us.

| Data | Where it lives |
|---|---|
| App settings and preferences (including your acceptance of these documents, recorded as a version and date) | macOS user defaults for the app |
| Your wallpaper library (imported and downloaded wallpapers) | A storage folder you choose. The default is `~/Documents/Open Wallpaper Engine` |
| Caches (for example, decoded images and translated shaders that speed up loading) | The app's cache folders on your Mac |
| A local copy of your own Wallpaper Engine assets, downloaded through your Steam account | Your storage folder |
| Your Steam Web API key (if you enter one) and your Steam account name (to reuse SteamCMD's saved login) | The macOS Keychain (see section 6) |

You can view, move or delete any of this at any time. Section 7 lists the locations.

## 4. Third parties the app contacts

OWE itself has no backend, but some features need the internet. When they do, the app connects directly from your Mac to the services below. We are not a party to those connections and do not receive their contents. Each of these services processes your data under **its own** privacy policy, which we encourage you to read.

### 4.1 Valve (Steam)

Used only for Steam Workshop features and for downloading your own copy of Wallpaper Engine's assets. These features are optional and require your own Steam account that owns Wallpaper Engine.

- **`api.steampowered.com`** — Workshop search, item details, collections and the list of your own Workshop subscriptions. If you enter a Steam Web API key, the app sends that key in a request header so Valve can authorise the request. Your IP address and the search terms or item IDs you ask for are necessarily part of these requests.
- **`steamcommunity.com`** — Workshop pages and related community content.
- **SteamCMD** — Valve's official command-line tool. OWE downloads it at runtime from Valve's content servers (`steamcdn-a.akamaihd.net`); it is not bundled with the app. SteamCMD then makes its own connections to Valve to log in and to download Workshop items and Wallpaper Engine's assets (Steam app 431960).

Your use of these services is subject to Valve's Steam Subscriber Agreement (https://store.steampowered.com/subscriber_agreement/) and Valve's Privacy Policy (https://store.steampowered.com/privacy_agreement/).

### 4.2 GitHub (app updates)

OWE uses the open-source Sparkle framework to check for new versions.

- It fetches an update feed from `https://openwallpaperengine.app/appcast.xml` (hosted by GitHub Pages) and downloads updates from GitHub Releases. The old feed address on `github.io` redirects there.
- Like any web request, these connections expose your IP address to GitHub, and Sparkle includes its standard request information, such as the app's name and version and your macOS version, so that a compatible update can be offered. We have not enabled Sparkle's optional "system profiling", so no hardware details are sent.
- We do not receive or log these requests; they go to GitHub's servers.

You can turn off automatic update checks in the app's Settings. GitHub's Privacy Statement applies: https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement.

### 4.3 Web wallpapers and other third-party content

"Web" wallpapers are HTML pages made by their creators. When you run one, it may load content from the internet exactly as a web page in a browser would — for example, a YouTube or Vimeo embed, fonts, images or scripts. Those requests go to the sites the wallpaper's author chose, are governed by those sites' policies, and are outside our control. Only install wallpapers from creators you trust (see also the Terms of Use).

### 4.4 Optional plugins and Send over Wi-Fi

- **Chromium web engine** (Settings › Plugins): downloaded only when you install it, from the Chromium Embedded Framework's official builds (`cef-builds.spotifycdn.com`), and checked against the SHA-256 the app pins.
- **Depth Map Generation** (Settings › Plugins): downloaded only when you install it, from Apple's Hugging Face repository (`huggingface.co`), and checked against the SHA-256 the app pins. The model runs only on your Mac.
- **MCP Server** (Settings › Plugins): while installed, the app opens a local control connection (a socket file in its support folder) that only your macOS user account can use, so AI assistants you run on your Mac can control the app. It never listens on the network; removing the plugin closes it.
- **Send over Wi-Fi** (Android export): while you share, the Mac serves only the packages you selected, to devices on your local network, until 15 minutes pass without a request. Nothing goes over the internet.

### 4.5 Links

Links in the app (to GitHub, Steam and so on) open in your default web browser. From that point on, your browser and the destination site apply.

## 5. macOS permissions and why we ask

OWE may ask for the following macOS permissions. Each is optional; the app works without it, minus the related feature. You can grant or revoke them at any time in **System Settings → Privacy & Security**.

| Permission | Why | What happens to the data |
|---|---|---|
| **System Audio Recording** (Screen & System Audio Recording before macOS 14.2) | Some wallpapers react to the audio playing on your Mac. macOS grants access to system audio through this permission. | Audio is analysed on your Mac in real time to drive the wallpaper's visuals. It is never recorded, saved or sent anywhere. Screen frames are not captured or used. |
| **Microphone** | Only when you choose a recording device (a microphone or a loopback device) in Settings › Optimizations › Audio, so audio-reactive wallpapers hear it instead of the audio your Mac plays. | Audio is analysed on your Mac in real time to drive the wallpaper's visuals. It is never recorded, saved or sent anywhere. |
| **Photos** | Only when you turn on "Also Save to Photos Album" for iPhone & iPad exports. | The app finds or creates the album you chose and adds your exported Live Photos to it. Nothing else is read, stored or transmitted. |
| **Local Network** | Send over Wi-Fi advertises the share's name on your local network. | Only the packages you selected are served, to devices on your local network. Nothing goes over the internet. |
| **Window information** (no prompt) | To pause wallpapers when a window covers a display, saving power. | The app only checks window positions and sizes on your Mac. Nothing is stored or transmitted. |
| **Now Playing (media information)** (no prompt) | Some wallpapers can display the current track title, artist and artwork. | Read from macOS's media information on your Mac and shown in the wallpaper. Nothing is stored or transmitted. |

## 6. Keychain and credentials

- If you enter a **Steam Web API key**, it is stored in the macOS Keychain on your Mac and used only in requests to `api.steampowered.com`. You can remove it from the app's Settings or with the Keychain Access app.
- Your **Steam account name** is stored in the Keychain so the app can reuse SteamCMD's saved login without asking again.
- Your **Steam password and Steam Guard codes are never stored or logged by OWE.** When you sign in through the app, they are passed only to SteamCMD, Valve's official tool, through its standard input. SteamCMD then keeps its own login token in its own folder, as it does when you use it directly. If you prefer, you can sign in with SteamCMD yourself in Terminal and the app will reuse that login.

## 7. Retention and deletion

We retain nothing, because we hold nothing. Your local data stays on your Mac until you delete it.

To remove everything OWE has stored, delete the app and these locations (paths may vary if you chose a different storage folder):

- **Wallpaper library and Wallpaper Engine assets:** the storage folder you chose (default `~/Documents/Open Wallpaper Engine`)
- **Settings:** the app's user defaults (`~/Library/Preferences/`, the entry named after the app's bundle identifier)
- **Caches:** the app's folder under `~/Library/Caches/`
- **Other app support files, including SteamCMD and its login token:** the app's folder under `~/Library/Application Support/`
- **Keychain entries:** the Steam Web API key and Steam account name, removable in the Keychain Access app

To delete data held by Valve or GitHub, use their tools and privacy policies, since that data is theirs, not ours.

## 8. Children

OWE is not directed at children under 13, or under 16 where a higher age applies (for example in parts of the European Economic Area). We do not knowingly collect personal data from anyone, including children. Steam Workshop features require a Steam account, which is subject to Valve's own age requirements.

## 9. Your rights and international users

### 9.1 Our position under data protection law

Because OWE processes data only on your own device, and we never receive, access or store any personal data, we do not act as a "controller" or "processor" of your personal data for the purposes of the EU General Data Protection Regulation (GDPR), the UK GDPR, or similar laws, and we do not "collect", "sell" or "share" personal information within the meaning of the California Consumer Privacy Act as amended by the California Privacy Rights Act (CCPA/CPRA).

Where the app connects to Valve or GitHub, those companies decide how they process the resulting data, and they, not we, are the controller or business for that processing. Please direct rights requests about that data to them.

### 9.2 Your rights

Rights of access, rectification, erasure, restriction, portability, objection and the right not to be discriminated against for exercising them (under GDPR, UK GDPR, CCPA/CPRA or similar laws) exist to protect you against organisations that hold your data. We hold none, so there is nothing for us to give you, correct or delete: your data is already in your hands and you can delete it as described in section 7. If you believe we have somehow received personal data about you, contact us (section 1) and we will look into it promptly.

You also have the right to lodge a complaint with a data protection supervisory authority in your country.

### 9.3 International transfers

We make no international transfers of personal data, since we make no transfers at all. Connections you make to Valve and GitHub may reach servers in other countries; their policies describe this.

## 10. Security

- Credentials are kept in the macOS Keychain, which encrypts them at rest and restricts access to the app.
- Passwords and Steam Guard codes are handled in memory only, for the duration of the sign-in, and passed only to Valve's SteamCMD.
- Update downloads are signed and verified before installation, so a tampered update will not install.
- All connections to Valve, GitHub and the plugin hosts use HTTPS. Send over Wi-Fi uses plain HTTP on your local network only, behind a random token.

No software is perfectly secure. Because OWE is open source, you can inspect exactly what it does. Please report security problems privately through the repository's Security tab ("Report a vulnerability"), as described in SECURITY.md.

## 11. Changes to this policy

We may update this policy when the app changes or the law requires it. The version number and effective date at the top will change. If a change is material, the app will ask you to review and accept the new version before continuing to use it. Earlier versions are available in the repository's history.

## 12. Contact

Questions or concerns: https://github.com/deepratna-awale/open-wallpaper-engine-mac/issues

---

*Wallpaper Engine is a product of Kristjan Skutta / Wallpaper Engine Team. Steam and the Steam logo are trademarks of Valve Corporation. GitHub is a trademark of GitHub, Inc. These names are used only to identify the services described above and imply no affiliation or endorsement.*


**Canada.** The publisher is based in Canada (St. John's, Newfoundland and Labrador). Because the publisher does not collect, use or disclose personal information through the app, the Personal Information Protection and Electronic Documents Act (PIPEDA) is not engaged by the app's operation; questions or concerns can still be raised through the contact below, and you may contact the Office of the Privacy Commissioner of Canada.
