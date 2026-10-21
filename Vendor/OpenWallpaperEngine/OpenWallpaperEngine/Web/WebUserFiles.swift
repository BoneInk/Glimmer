import Foundation

/// The files outside a web wallpaper's folder its page may read: the ones the user chose for its
/// `file` properties and, for its `directory` properties, the matching files in the chosen
/// folders. Pages ask for them as WE documents, `'file:///' + value`; the start script
/// (`userFileScript`) points such URLs at `owe-wallpaper://local/.owe-user-files/<path>`, which
/// `WebWallpaperSchemeHandler` serves only when this allows the path. Thread-safe: the view model
/// updates it on the main thread, Chromium's requests read it on XPC's queue.
final class WebUserFiles: Equatable, @unchecked Sendable {
    /// One page's set: two are the same only if they are the same object.
    static func == (lhs: WebUserFiles, rhs: WebUserFiles) -> Bool { lhs === rhs }

    /// The served path every user file sits below.
    static let pathPrefix = ".owe-user-files"

    private struct Folder: Equatable {
        let root: String
        let type: WebDirectoryProperty.FileType
    }

    private let lock = NSLock()
    // `lock` guards both.
    private var files: Set<String> = []
    private var folders: [Folder] = []

    /// Allows exactly `filePaths` and the matching files below each folder, replacing what was
    /// allowed before. Paths that don't exist are dropped.
    func allow(filePaths: [String], folders newFolders: [(path: String, type: WebDirectoryProperty.FileType)]) {
        let canonicalFiles = Set(filePaths.compactMap { ContainedPath.canonical(URL(fileURLWithPath: $0)) })
        let canonicalFolders = newFolders.compactMap { folder -> Folder? in
            ContainedPath.canonical(URL(fileURLWithPath: folder.path)).map { Folder(root: $0, type: folder.type) }
        }
        lock.withLock {
            files = canonicalFiles
            folders = canonicalFolders
        }
    }

    /// The file a request for `relativePath` (below `pathPrefix`) names, if the page may read it.
    func file(forServedPath relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/")
        guard components.first.map(String.init) == Self.pathPrefix, components.count > 1,
              !components.contains("..") else { return nil }
        let path = "/" + components.dropFirst().joined(separator: "/")
        guard let canonical = ContainedPath.canonical(URL(fileURLWithPath: path)) else { return nil }
        let url = URL(fileURLWithPath: canonical)
        let allowed = lock.withLock {
            files.contains(canonical) || folders.contains {
                canonical != $0.root && ContainedPath.isInside(canonical, root: $0.root) && $0.type.matches(url)
            }
        }
        guard allowed,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
    }

    /// Run at document start in both engines, before the page's own scripts: a `file://` URL the
    /// page hands to the DOM, CSS, `fetch` or XHR is pointed at the user-file path of this origin,
    /// as WE's file pages open such URLs directly. Strings without one pass through unchanged.
    static let userFileScript = """
    (function(){
      if (window.__oweUserFiles || location.protocol !== '\(WebWallpaperSchemeHandler.scheme):') return;
      window.__oweUserFiles = true;
      var BASE = location.protocol + '//' + location.host + '/\(pathPrefix)/';
      var FILE = /\\bfile:\\/\\/+/gi;
      var map = function(v){ return typeof v === 'string' && v.search(FILE) >= 0 ? v.replace(FILE, BASE) : v; };
      var owner = function(obj, name){
        while (obj && !Object.getOwnPropertyDescriptor(obj, name)) obj = Object.getPrototypeOf(obj);
        return obj;
      };
      var wrap = function(obj, name, when){
        var proto = owner(obj, name); if (!proto) return;
        var d = Object.getOwnPropertyDescriptor(proto, name);
        if (!d || !d.set || !d.configurable) return;
        Object.defineProperty(proto, name, { configurable: true, enumerable: d.enumerable, get: d.get,
          set: function(v){ d.set.call(this, when && !when(this) ? v : map(v)); } });
      };
      [['HTMLImageElement','src'],['HTMLImageElement','srcset'],['HTMLMediaElement','src'],
       ['HTMLSourceElement','src'],['HTMLSourceElement','srcset'],['HTMLVideoElement','poster'],
       ['HTMLTrackElement','src'],['HTMLIFrameElement','src'],['HTMLEmbedElement','src'],
       ['HTMLObjectElement','data'],['HTMLScriptElement','src'],['HTMLLinkElement','href'],
       ['HTMLInputElement','src'],['HTMLElement','style'],['Element','innerHTML'],['Element','outerHTML']
      ].forEach(function(p){ var c = window[p[0]]; if (c) wrap(c.prototype, p[1]); });
      if (window.Node && window.HTMLStyleElement) {
        wrap(Node.prototype, 'textContent', function(node){ return node instanceof HTMLStyleElement; });
      }
      var style = document.createElement('div').style;
      ['background','backgroundImage','background-image','cssText','borderImage','border-image',
       'borderImageSource','border-image-source','listStyle','list-style','listStyleImage','list-style-image',
       'mask','maskImage','mask-image','webkitMaskImage','-webkit-mask-image','content','cursor'
      ].forEach(function(name){ wrap(style, name); });
      var patch = function(proto, name, index){
        var f = proto && proto[name]; if (typeof f !== 'function') return;
        proto[name] = function(){
          var args = Array.prototype.slice.call(arguments);
          if (args.length > index) args[index] = map(args[index]);
          return f.apply(this, args);
        };
      };
      patch(Element.prototype, 'setAttribute', 1);
      patch(Element.prototype, 'setAttributeNS', 2);
      patch(Element.prototype, 'insertAdjacentHTML', 1);
      patch(window.CSSStyleDeclaration && CSSStyleDeclaration.prototype, 'setProperty', 1);
      patch(window.CSSStyleSheet && CSSStyleSheet.prototype, 'insertRule', 0);
      patch(window.XMLHttpRequest && XMLHttpRequest.prototype, 'open', 1);
      patch(window, 'fetch', 0);
      if (typeof window.Audio === 'function') {
        var NativeAudio = window.Audio;
        var Audio = function(src){ return arguments.length ? new NativeAudio(map(src)) : new NativeAudio(); };
        Audio.prototype = NativeAudio.prototype;
        window.Audio = Audio;
      }
    })();
    """
}
