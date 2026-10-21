import Foundation

/// Local author scripts run in the page world. The only native message channel reports
/// document readiness, delivery acknowledgements and errors; it performs no file/shell work.
enum WebWallpaperBridge {
    static func script(token: String) -> String {
        let literal = String(decoding: try! JSONSerialization.data(withJSONObject: token, options: [.fragmentsAllowed]), as: UTF8.self)
        return "const __gwDocumentToken = \(literal);\n" + WebWallpaperResourceBridge.script + "\n" + body
    }
    private static let body = #"""
    (() => {
      'use strict';
      const token = __gwDocumentToken;
      const post = (kind, detail = {}) => {
        try { window.webkit.messageHandlers.gwWallpaper.postMessage({token, kind, ...detail}); } catch (_) {}
      };
      let listener;
      let directories = {}, directoriesJSON = '{}', deliveredDirectories = null;
      let desired = {}, general = {fps: 30}, paused = false, revision = -1, received = false, documentReady = false;
      let delivered = null, deliveredGeneral = null, deliveredPause;
      let deliveryListener = null, draining = false, queued = false, rerun = false;
      const observed = new WeakSet();
      const signature = value => JSON.stringify(value);
      const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
      const method = key => {
        const current = window.wallpaperPropertyListener;
        return current && typeof current[key] === 'function' ? [current, current[key]] : null;
      };
      const enqueue = () => {
        if (queued) return;
        queued = true;
        queueMicrotask(() => { queued = false; void drain(); });
      };
      const observe = object => {
        if (!object || (typeof object !== 'object' && typeof object !== 'function') || observed.has(object)) return object;
        observed.add(object);
        for (const key of ['applyUserProperties','applyGeneralProperties','setPaused','userDirectoryFilesAddedOrChanged','userDirectoryFilesRemoved']) {
          const descriptor = Object.getOwnPropertyDescriptor(object, key);
          // Preserve custom accessors and sealed authored objects. A normal object or
          // method assigned after the global listener is installed gets a setter handshake.
          if (descriptor && (!descriptor.configurable || descriptor.get || descriptor.set)) continue;
          let value = object[key];
          try {
            Object.defineProperty(object, key, {configurable: true, enumerable: true,
              get() { return value; }, set(next) {
                value = next;
                if (key === 'applyUserProperties') { delivered = null; deliveryListener = null; }
                if (key === 'applyGeneralProperties') deliveredGeneral = null;
                if (key === 'setPaused') deliveredPause = undefined;
                if (key.startsWith('userDirectory')) deliveredDirectories = null;
                enqueue();
              }});
          } catch (_) {}
        }
        return object;
      };
      Object.defineProperty(window, 'wallpaperPropertyListener', {
        configurable: true, enumerable: true,
        get() { return listener; },
        set(next) { listener = observe(next); enqueue(); }
      });
      async function drain() {
        if (draining) { rerun = true; return; }
        if (!received || !documentReady) return;
        draining = true;
        try {
          const current = window.wallpaperPropertyListener;
          observe(current);
          post('capabilities', {userPropertiesListener:!!method('applyUserProperties'),directoryListener:!!method('userDirectoryFilesAddedOrChanged') && !!method('userDirectoryFilesRemoved')});
          if (current !== deliveryListener) {
            deliveryListener = current; delivered = null; deliveredGeneral = null; deliveredPause = undefined; deliveredDirectories = null;
          }
          const user = method('applyUserProperties');
          if (!user) post('waiting');
          // One call at a time. State that changes while an authored async listener
          // is outstanding stays pending and is compared against its accepted snapshot.
          const snapshot = JSON.parse(JSON.stringify(desired));
          const snapshotRevision = revision;
          const diff = Object.create(null);
          for (const key of Object.keys(snapshot)) {
            if (delivered === null || !own(delivered, key) || signature(snapshot[key]) !== signature(delivered[key])) diff[key] = snapshot[key];
          }
          const initial = delivered === null;
          if (user && (initial || Object.keys(diff).length)) {
            try { await user[1].call(user[0], diff); }
            catch (error) {
              post('propertiesError', {revision: snapshotRevision, propertiesJSON: signature(snapshot), message: String(error && error.message || error).slice(0, 2048)});
              if (signature(snapshot) !== signature(desired)) enqueue();
              return;
            }
            if (window.wallpaperPropertyListener !== current || deliveryListener !== current) { enqueue(); return; }
            delivered = snapshot;
            post('propertiesApplied', {keys: Object.keys(diff), initial});
          }
          if (user) post('propertiesConsumed', {revision: snapshotRevision, propertiesJSON: signature(snapshot)});
          const directorySnapshot = JSON.parse(directoriesJSON), directoryJSONSnapshot = directoriesJSON, directoryRevision = revision;
          let directoryComplete = true;
          try {
            const previous = deliveredDirectories || {};
            for (const key of new Set([...Object.keys(previous),...Object.keys(directorySnapshot)])) {
              const before = previous[key], after = directorySnapshot[key];
              const oldFiles = before && before.mode === 'fetchall' ? before.files : [];
              const newFiles = after && after.mode === 'fetchall' ? after.files : [];
              const removed = oldFiles.filter(file=>!newFiles.some(next=>next.path===file.path)).map(file=>file.path);
              const added = newFiles.filter(file=>!oldFiles.some(old=>old.path===file.path && old.identity===file.identity)).map(file=>file.path);
              if (removed.length) {
                const callback = method('userDirectoryFilesRemoved');
                if (!callback) { directoryComplete=false; break; }
                await callback[1].call(callback[0],key,removed);
                if (window.wallpaperPropertyListener !== current) { enqueue(); return; }
              }
              if (after && after.mode === 'fetchall' && (added.length || !before || before.mode !== 'fetchall')) {
                const callback = method('userDirectoryFilesAddedOrChanged');
                if (!callback) { directoryComplete=false; break; }
                await callback[1].call(callback[0],key,added);
                if (window.wallpaperPropertyListener !== current) { enqueue(); return; }
              }
            }
            if (directoryComplete) {
              deliveredDirectories = directorySnapshot;
              post('directoriesConsumed',{revision:directoryRevision,directoriesJSON:directoryJSONSnapshot});
            }
          } catch(error) {
            post('directoriesError',{revision:directoryRevision,directoriesJSON:directoryJSONSnapshot,message:String(error && error.message || error).slice(0,2048)});
            if(directoryJSONSnapshot!==directoriesJSON)enqueue();
            return;
          }
          const settings = method('applyGeneralProperties');
          const settingsSnapshot = JSON.parse(JSON.stringify(general));
          if (settings && signature(settingsSnapshot) !== signature(deliveredGeneral)) {
            const changes = Object.create(null);
            for (const key of Object.keys(settingsSnapshot)) {
              if (deliveredGeneral === null || signature(settingsSnapshot[key]) !== signature(deliveredGeneral[key])) changes[key] = settingsSnapshot[key];
            }
            await settings[1].call(settings[0], changes);
            deliveredGeneral = settingsSnapshot;
          }
          const pause = method('setPaused');
          const pauseSnapshot = paused;
          if (pause && pauseSnapshot !== deliveredPause) {
            await pause[1].call(pause[0], pauseSnapshot);
            deliveredPause = pauseSnapshot;
          }
          post('ready', {paused,userPropertiesListener:!!method('applyUserProperties'),directoryListener:!!method('userDirectoryFilesAddedOrChanged') && !!method('userDirectoryFilesRemoved')});
          if (signature(snapshot) !== signature(desired) || signature(settingsSnapshot) !== signature(general) || pauseSnapshot !== paused || directoryJSONSnapshot !== directoriesJSON) enqueue();
        } catch (error) {
          post('scriptError', {message: String(error && error.message || error).slice(0, 2048)});
        } finally { draining = false; if (rerun) { rerun = false; enqueue(); } }
      }
      window.__gwWallpaperReceive = (expectedToken, nextRevision, propertiesJSON, generalJSON, nextPaused, nextDirectoriesJSON) => {
        if (expectedToken !== token || nextRevision < revision) return;
        revision = nextRevision; received = true;
        desired = JSON.parse(propertiesJSON); general = JSON.parse(generalJSON); paused = !!nextPaused;
        directoriesJSON = nextDirectoriesJSON; directories = JSON.parse(directoriesJSON);
        enqueue();
      };
      window.wallpaperRequestRandomFileForProperty = (propertyName, callback) => {
        if(typeof callback!=='function')return;
        const directory=directories[propertyName];
        const files=directory && directory.mode==='ondemand' ? directory.files : [];
        const file=files.length ? files[Math.floor(Math.random()*files.length)].path : '';
        queueMicrotask(()=>{try{callback(propertyName,file);}catch(error){post('scriptError',{message:String(error && error.message || error).slice(0,2048)});}});
      };
      const ready = () => { documentReady = true; post('documentReady'); enqueue(); };
      document.addEventListener('DOMContentLoaded', ready, {once: true});
      window.addEventListener('load', ready, {once: true});
      window.addEventListener('error', event => {
        const message = event.message || 'A local wallpaper resource failed to load.';
        post('scriptError', {message: String(message).slice(0, 2048)});
      }, true);
      window.addEventListener('unhandledrejection', event => post('scriptError', {message: String(event.reason && event.reason.message || event.reason).slice(0, 2048)}));
      document.addEventListener('securitypolicyviolation', event => post('securityError', {message: 'Blocked a wallpaper resource or operation outside the local project policy.', uri: event.blockedURI, directive: event.effectiveDirective}));
      post('bootstrap');
    })();
    """#
}
