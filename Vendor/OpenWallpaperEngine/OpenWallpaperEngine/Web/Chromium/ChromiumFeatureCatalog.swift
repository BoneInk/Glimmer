import Foundation

/// Web APIs a wallpaper may use that Chromium (WE's CEF) has and WebKit on macOS 26 does not.
///
/// The list is built from WebKit's real gaps, each with its source, and checked against WebKit's
/// feature status (webkit.org/status, WebKit standards positions) and caniuse/MDN browser-compat
/// data for Safari through 26. A feature counts only when the page *uses* it (calls a method,
/// reads a member, constructs it), not when it merely tests for it: `if (navigator.serial)` is a
/// page that copes without it, `navigator.serial.requestPort()` is one that needs it.
///
/// Left out on purpose (documented in docs/chromium-engine.md):
/// - present in Safari 26: WebGPU, OffscreenCanvas, CompressionStream, Screen Wake Lock,
///   `requestVideoFrameCallback`, `CSS.registerProperty`, Web Speech recognition (prefixed);
/// - uncertain for Safari 26, so not counted: `requestIdleCallback`, `scheduler.postTask`,
///   Trusted Types, `BarcodeDetector`, `AudioContext.setSinkId`;
/// - missing but harmless (pages fall back): `navigator.deviceMemory`, `navigator.connection`;
/// - `-webkit-app-region`: no effect in any browser tab, Chromium's included, so it needs nothing.
struct ChromiumFeature: Identifiable, Equatable {
    /// Stable id, stored with a wallpaper's findings.
    let id: String
    /// The API as a developer writes it; shown untranslated, it is code.
    let api: String
    /// Regular expressions over the page's code with strings and comments blanked out.
    let staticPatterns: [String]
    /// Text that names the API in WebKit's TypeError/ReferenceError messages.
    let runtimeTokens: [String]
    /// Where the gap is documented.
    let source: String
}

enum ChromiumFeatureCatalog {
    static let all: [ChromiumFeature] = [
        ChromiumFeature(
            id: "chrome-apis", api: "window.chrome",
            staticPatterns: [#"(?<![\w$])chrome\s*\.\s*(runtime|webstore|app|csi|loadTimes|storage|tabs|extension|i18n)\b"#],
            runtimeTokens: ["chrome.runtime", "chrome.webstore", "chrome.app", "chrome.csi", "chrome.loadTimes",
                            "chrome.storage", "Can't find variable: chrome"],
            source: "Chrome-only global (not in any WebKit build); MDN: not standard"),
        ChromiumFeature(
            id: "css-paint", api: "CSS.paintWorklet",
            staticPatterns: [#"\bpaintWorklet\s*\.\s*addModule\b"#, #"\bregisterPaint\s*\("#],
            runtimeTokens: ["paintWorklet", "registerPaint"],
            source: "caniuse css-paint-api: Safari not supported (behind a flag); webkit.org/status CSS Painting API"),
        ChromiumFeature(
            id: "ua-client-hints", api: "navigator.userAgentData",
            staticPatterns: [#"\buserAgentData\s*\.\s*(getHighEntropyValues|brands|mobile|platform|toJSON)\b"#],
            runtimeTokens: ["userAgentData"],
            source: "WebKit standards position: oppose (User-Agent Client Hints); caniuse mdn-api_navigator_useragentdata"),
        ChromiumFeature(
            id: "web-serial", api: "navigator.serial",
            staticPatterns: [#"\bnavigator\s*\.\s*serial\s*\.\s*(requestPort|getPorts|addEventListener|onconnect|ondisconnect)\b"#],
            runtimeTokens: ["navigator.serial", "serial.requestPort", "serial.getPorts"],
            source: "WebKit standards position: oppose (Web Serial); caniuse web-serial"),
        ChromiumFeature(
            id: "webusb", api: "navigator.usb",
            staticPatterns: [#"\bnavigator\s*\.\s*usb\s*\.\s*(requestDevice|getDevices|addEventListener|onconnect|ondisconnect)\b"#],
            runtimeTokens: ["navigator.usb", "usb.requestDevice", "usb.getDevices"],
            source: "WebKit standards position: oppose (WebUSB); caniuse webusb"),
        ChromiumFeature(
            id: "webhid", api: "navigator.hid",
            staticPatterns: [#"\bnavigator\s*\.\s*hid\s*\.\s*(requestDevice|getDevices|addEventListener|onconnect|ondisconnect)\b"#],
            runtimeTokens: ["navigator.hid", "hid.requestDevice", "hid.getDevices"],
            source: "WebKit standards position: oppose (WebHID); caniuse webhid"),
        ChromiumFeature(
            id: "web-bluetooth", api: "navigator.bluetooth",
            staticPatterns: [#"\bnavigator\s*\.\s*bluetooth\s*\.\s*(requestDevice|getAvailability|getDevices|requestLEScan|addEventListener)\b"#],
            runtimeTokens: ["navigator.bluetooth", "bluetooth.requestDevice", "bluetooth.getAvailability"],
            source: "WebKit standards position: oppose (Web Bluetooth); caniuse web-bluetooth"),
        ChromiumFeature(
            id: "feature-policy", api: "document.featurePolicy",
            staticPatterns: [#"\bfeaturePolicy\s*\.\s*(allowsFeature|features|allowedFeatures|getAllowlistForFeature)\b"#],
            runtimeTokens: ["featurePolicy"],
            source: "Chrome-only (superseded by Permissions Policy); MDN: Safari not supported"),
        ChromiumFeature(
            id: "file-system-access", api: "showOpenFilePicker()",
            staticPatterns: [#"\b(showOpenFilePicker|showSaveFilePicker|showDirectoryPicker)\s*\("#],
            runtimeTokens: ["showOpenFilePicker", "showSaveFilePicker", "showDirectoryPicker"],
            source: "caniuse native-filesystem-api: Safari has only the origin private file system, no pickers"),
        ChromiumFeature(
            id: "battery", api: "navigator.getBattery()",
            staticPatterns: [#"\bgetBattery\s*\("#],
            runtimeTokens: ["getBattery"],
            source: "caniuse battery-status: Safari not supported (removed from WebKit)"),
        ChromiumFeature(
            id: "eyedropper", api: "EyeDropper",
            staticPatterns: [#"\bnew\s+EyeDropper\b"#],
            runtimeTokens: ["EyeDropper"],
            source: "caniuse mdn-api_eyedropper: Safari not supported"),
        ChromiumFeature(
            id: "keyboard-map", api: "navigator.keyboard",
            staticPatterns: [#"\bnavigator\s*\.\s*keyboard\s*\.\s*(getLayoutMap|lock|unlock)\b"#],
            runtimeTokens: ["navigator.keyboard", "getLayoutMap"],
            source: "WebKit standards position: oppose (Keyboard Map and Keyboard Lock); MDN: Safari not supported"),
        ChromiumFeature(
            id: "local-fonts", api: "queryLocalFonts()",
            staticPatterns: [#"\bqueryLocalFonts\s*\("#],
            runtimeTokens: ["queryLocalFonts"],
            source: "WebKit standards position: oppose (Local Font Access); MDN: Safari not supported"),
        ChromiumFeature(
            id: "document-pip", api: "documentPictureInPicture",
            staticPatterns: [#"\bdocumentPictureInPicture\s*\.\s*(requestWindow|window|addEventListener)\b"#],
            runtimeTokens: ["documentPictureInPicture"],
            source: "caniuse mdn-api_documentpictureinpicture: Safari not supported"),
        ChromiumFeature(
            id: "performance-memory", api: "performance.memory",
            staticPatterns: [#"\bperformance\s*\.\s*memory\s*\.\s*(usedJSHeapSize|totalJSHeapSize|jsHeapSizeLimit)\b"#],
            runtimeTokens: ["performance.memory"],
            source: "Chrome-only, non-standard; MDN: Safari not supported"),
        ChromiumFeature(
            id: "chrome-file-system", api: "webkitRequestFileSystem()",
            staticPatterns: [#"\b(webkitRequestFileSystem|requestFileSystem)\s*\("#],
            runtimeTokens: ["webkitRequestFileSystem", "requestFileSystem"],
            source: "Chrome-only FileSystem API (never in WebKit); MDN: Safari not supported"),
        ChromiumFeature(
            id: "idle-detection", api: "IdleDetector",
            staticPatterns: [#"\bnew\s+IdleDetector\b"#, #"\bIdleDetector\s*\.\s*requestPermission\b"#],
            runtimeTokens: ["IdleDetector"],
            source: "WebKit standards position: oppose (Idle Detection); caniuse mdn-api_idledetector"),
        ChromiumFeature(
            id: "window-management", api: "getScreenDetails()",
            staticPatterns: [#"\bgetScreenDetails\s*\("#],
            runtimeTokens: ["getScreenDetails"],
            source: "Window Management API: Chromium only; MDN: Safari not supported"),
        ChromiumFeature(
            id: "compute-pressure", api: "PressureObserver",
            staticPatterns: [#"\bnew\s+PressureObserver\b"#],
            runtimeTokens: ["PressureObserver"],
            source: "Compute Pressure API: Chromium only; MDN: Safari not supported"),
    ]

    static func feature(id: String) -> ChromiumFeature? {
        all.first { $0.id == id }
    }

    /// `ids` in the catalog's order, unknown ones dropped.
    static func ordered(_ ids: some Sequence<String>) -> [ChromiumFeature] {
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }

    /// The features a WebKit error names: only TypeErrors and ReferenceErrors count, the errors a
    /// missing API raises ("undefined is not an object (evaluating 'navigator.serial.requestPort')",
    /// "Can't find variable: EyeDropper").
    static func features(inError type: String, message: String) -> [ChromiumFeature] {
        guard type == "TypeError" || type == "ReferenceError" else { return [] }
        return all.filter { feature in feature.runtimeTokens.contains { message.contains($0) } }
    }

    /// Compiled once.
    static let compiledPatterns: [(id: String, patterns: [NSRegularExpression])] = all.map { feature in
        (feature.id, feature.staticPatterns.compactMap { pattern in
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                OWELog.error(.web, "Chromium feature pattern \(pattern) doesn't compile: \(error)")
                return nil
            }
        })
    }
}
