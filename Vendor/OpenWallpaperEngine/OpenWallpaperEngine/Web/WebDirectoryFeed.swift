import Foundation

/// One page's `directory` properties (`WebDirectoryProperty`): watches each chosen folder, keeps
/// its matching files, sends a `fetchall` property's additions, changes and removals to the page
/// once it has loaded, and answers an `ondemand` property's requests with a random file. The same
/// for WebKit and Chromium; `send` evaluates the scripts in whichever page is current. Main thread.
@MainActor
final class WebDirectoryFeed {
    /// The message `wallpaperRequestRandomFileForProperty` posts: `{id, property}`.
    static let randomFileMessageName = "oweRandomFile"

    private struct Watch {
        let property: WebDirectoryProperty
        let folder: String
        let watcher: WebDirectoryWatcher
        /// nil until the first listing.
        var files: [String: Date]?
        /// What the page has been sent (`fetchall`).
        var sent: [String: Date] = [:]
        /// Requests that came before the first listing (`ondemand`).
        var waiting: [Int] = []
    }

    private var watches: [String: Watch] = [:]
    private var pageLoaded = false
    /// Evaluates a script in the current page.
    var send: (String) -> Void = { _ in }
    /// Called whenever the folders change, with each folder and its file type, for serving.
    var onFoldersChange: ([(path: String, type: WebDirectoryProperty.FileType)]) -> Void = { _ in }
    /// Picks the random file; replaceable in tests.
    var pick: ([String]) -> String? = { $0.randomElement() }

    deinit {
        // Each watcher must be stopped before it goes (its stream points at it); `stop` holds it
        // until the stream is released.
        let watchers = watches.values.map(\.watcher)
        MainActor.assumeIsolated { watchers.forEach { $0.stop() } }
    }

    /// Watches the folder each of `properties` is set to in `values` (an empty value: none),
    /// keeping a watch whose folder didn't change. A property that lost its folder has its files
    /// removed from the page.
    func update(properties: [WebDirectoryProperty], values: [String: String]) {
        var wanted: [String: (WebDirectoryProperty, String)] = [:]
        for property in properties {
            let value = values[property.key] ?? ""
            guard !value.isEmpty else { continue }
            let folder = URL(fileURLWithPath: value).standardizedFileURL.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                OWELog.error(.web, "Not a directory: \(URL(fileURLWithPath: folder).lastPathComponent) (property \(property.key))")
                continue
            }
            wanted[property.key] = (property, folder)
        }
        for (key, watch) in watches where wanted[key].map({ $0.0 != watch.property || $0.1 != watch.folder }) ?? true {
            watch.watcher.stop()
            answerWaiting(watch.waiting, property: key, files: [])
            if pageLoaded, watch.property.mode == .fetchAll, !watch.sent.isEmpty {
                send(Self.removedScript(property: key, paths: watch.sent.keys.sorted()))
            }
            watches[key] = nil
        }
        for (key, (property, folder)) in wanted where watches[key] == nil {
            let watcher = WebDirectoryWatcher(folder: URL(fileURLWithPath: folder), fileType: property.fileType) {
                [weak self] files in self?.listed(files, property: key, folder: folder)
            }
            watches[key] = Watch(property: property, folder: folder, watcher: watcher)
            watcher.start()
        }
        onFoldersChange(watches.values.map { ($0.folder, $0.property.fileType) })
    }

    /// A new page is loading: it has none of the files yet.
    func pageWillLoad() {
        pageLoaded = false
        for key in watches.keys { watches[key]?.sent = [:] }
    }

    /// The page loaded and has its properties: it gets every `fetchall` file listed so far.
    func pageDidLoad() {
        pageLoaded = true
        for key in watches.keys.sorted() { sync(key) }
    }

    /// `wallpaperRequestRandomFileForProperty`'s message.
    func receiveRequest(_ body: Any) {
        guard let object = body as? [String: Any], let id = (object["id"] as? NSNumber)?.intValue,
              let property = object["property"] as? String else {
            OWELog.debug(.web, "Ignoring a malformed random file request")
            return
        }
        guard var watch = watches[property] else {
            // No folder chosen (or no such property): the page hears that there is no file.
            send(Self.responseScript(id: id, property: property, path: ""))
            return
        }
        guard let files = watch.files else {
            watch.waiting.append(id)
            watches[property] = watch
            return
        }
        send(Self.responseScript(id: id, property: property, path: pick(Array(files.keys)).map(WebDirectoryProperty.pagePath) ?? ""))
    }

    private func listed(_ files: [String: Date], property key: String, folder: String) {
        guard var watch = watches[key], watch.folder == folder else { return }
        watch.files = files
        let waiting = watch.waiting
        watch.waiting = []
        watches[key] = watch
        answerWaiting(waiting, property: key, files: Array(files.keys))
        sync(key)
    }

    private func answerWaiting(_ ids: [Int], property: String, files: [String]) {
        for id in ids {
            send(Self.responseScript(id: id, property: property, path: pick(files).map(WebDirectoryProperty.pagePath) ?? ""))
        }
    }

    /// Sends a loaded page what changed in a `fetchall` folder since it was last sent.
    private func sync(_ key: String) {
        guard pageLoaded, var watch = watches[key], watch.property.mode == .fetchAll, let files = watch.files else { return }
        let (changed, removed) = WebDirectoryProperty.changes(from: watch.sent, to: files)
        if !removed.isEmpty { send(Self.removedScript(property: key, paths: removed)) }
        if !changed.isEmpty { send(Self.changedScript(property: key, paths: changed)) }
        watch.sent = files
        watches[key] = watch
    }

    // MARK: Scripts

    static func changedScript(property: String, paths: [String]) -> String {
        call("__oweDirectoryFilesChanged", property: property, paths: paths)
    }

    static func removedScript(property: String, paths: [String]) -> String {
        call("__oweDirectoryFilesRemoved", property: property, paths: paths)
    }

    static func responseScript(id: Int, property: String, path: String) -> String {
        "window.__oweRandomFileResponse&&window.__oweRandomFileResponse(\(id),\(json(property)),\(json(path)));"
    }

    private static func call(_ function: String, property: String, paths: [String]) -> String {
        "window.\(function)&&window.\(function)(\(json(property)),\(json(paths.map(WebDirectoryProperty.pagePath))));"
    }

    private static func json(_ value: Any) -> String {
        // A string or an array of strings always serializes.
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Run at document start in both engines: WE's `wallpaperRequestRandomFileForProperty`, and
    /// the delivery of directory files to `wallpaperPropertyListener` (which `bootstrapScript`
    /// traps). A listener assigned after files arrived gets the current set when it is assigned.
    static let bootstrapScript = """
    (function(){
      if (window.__oweDirectoryBridge) return; window.__oweDirectoryBridge = true;
      var requests = {}, next = 1, folders = {}, sentTo = null;
      window.wallpaperRequestRandomFileForProperty = function(name, callback){
        if (typeof callback !== 'function') return;
        var id = next++; requests[id] = callback;
        try { window.webkit.messageHandlers.\(randomFileMessageName).postMessage({ id: id, property: String(name) }); }
        catch(e) { delete requests[id]; }
      };
      window.__oweRandomFileResponse = function(id, name, path){
        var callback = requests[id]; delete requests[id];
        if (callback) { try { callback(name, path); } catch(e) { console.error(e); } }
      };
      var call = function(name, property, paths){
        var l = window.wallpaperPropertyListener;
        if (l && typeof l[name] === 'function') { try { l[name](property, paths.slice()); } catch(e) { console.error(e); } }
      };
      var catchUp = function(){
        var l = window.wallpaperPropertyListener;
        if (!l || sentTo === l) return;
        sentTo = l;
        for (var p in folders) { var all = Object.keys(folders[p]); if (all.length) call('userDirectoryFilesAddedOrChanged', p, all); }
      };
      window.__oweDirectoryListenerAssigned = catchUp;
      window.__oweDirectoryFilesChanged = function(property, paths){
        var set = folders[property] || (folders[property] = {});
        paths.forEach(function(p){ set[p] = true; });
        if (sentTo === window.wallpaperPropertyListener) call('userDirectoryFilesAddedOrChanged', property, paths); else catchUp();
      };
      window.__oweDirectoryFilesRemoved = function(property, paths){
        var set = folders[property] || {};
        paths.forEach(function(p){ delete set[p]; });
        if (sentTo === window.wallpaperPropertyListener) call('userDirectoryFilesRemoved', property, paths); else catchUp();
      };
    })();
    """
}
