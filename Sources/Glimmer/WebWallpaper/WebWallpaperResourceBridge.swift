import Foundation

/// Compatibility is deliberately limited to the opaque native-granted namespace.
/// Arbitrary file: URLs remain blocked by WebKit/CSP and never reach a native file API.
enum WebWallpaperResourceBridge {
    static let script = #"""
    (() => {
      const nativePrefix = 'file:///__gw_assets__/';
      const rewrite = value => {
        const text = String(value);
        if (!text.startsWith(nativePrefix)) return value;
        const relative = text.slice('file:///'.length);
        return 'gw-wallpaper://project/__gw_grants__/' + encodeURIComponent(__gwDocumentToken) + '/' + relative.split('/').map(encodeURIComponent).join('/');
      };
      const css = value => String(value).replace(/url\(\s*(?:(['"])(file:\/\/\/__gw_assets__\/.*?)\1|(file:\/\/\/__gw_assets__\/[^\s)]*))\s*\)/gi, (_,quote,quoted,bare) => 'url("' + rewrite(quoted || bare).replace(/"/g,'%22') + '")');
      const wrapProperty = (prototype, key, transform) => {
        const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
        if (!descriptor || !descriptor.set || !descriptor.configurable) return;
        Object.defineProperty(prototype, key, {...descriptor, set(value) { descriptor.set.call(this, transform(value)); }});
      };
      for (const [type,key] of [[HTMLImageElement,'src'],[HTMLMediaElement,'src'],[HTMLSourceElement,'src'],[HTMLVideoElement,'poster']]) wrapProperty(type.prototype,key,rewrite);
      const originalAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(key,value) {
        const lower = String(key).toLowerCase();
        if (['src','poster'].includes(lower)) value = rewrite(value);
        else if (lower === 'style') value = css(value);
        return originalAttribute.call(this,key,value);
      };
      for (const key of ['background','backgroundImage','borderImage','borderImageSource','listStyleImage','content','cssText']) wrapProperty(CSSStyleDeclaration.prototype,key,css);
      const setProperty = CSSStyleDeclaration.prototype.setProperty;
      CSSStyleDeclaration.prototype.setProperty = function(key,value,priority) { return setProperty.call(this,key,css(value),priority); };
      const insertRule = CSSStyleSheet.prototype.insertRule;
      CSSStyleSheet.prototype.insertRule = function(rule,index) { return insertRule.call(this,css(rule),index); };
      const nativeFetch = window.fetch;
      window.fetch = function(input,options) { return nativeFetch.call(this,typeof input === 'string' || input instanceof URL ? rewrite(input) : input,options); };
      const NativeAudio = window.Audio;
      window.Audio = new Proxy(NativeAudio,{construct(target,args,newTarget) { if(args.length)args[0]=rewrite(args[0]);return Reflect.construct(target,args,newTarget); }});
      const NativeRequest = window.Request;
      window.Request = new Proxy(NativeRequest,{construct(target,args,newTarget) { if (typeof args[0] === 'string' || args[0] instanceof URL) args[0]=rewrite(args[0]);return Reflect.construct(target,args,newTarget); }});
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method,url,...rest) { return open.call(this,method,rewrite(url),...rest); };
      // Parsed HTML/style text is observed as a fallback. Common property setters above
      // rewrite synchronously, before WebKit attempts a file: request.
      const fixTree = node => {
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        for (const element of [node,...node.querySelectorAll('[src],[poster],[style],style')]) {
          for (const key of ['src','poster']) if (element.hasAttribute(key)) {
            const value=element.getAttribute(key), next=rewrite(value);if(next!==value)originalAttribute.call(element,key,next);
          }
          if(element.hasAttribute('style')) {const value=element.getAttribute('style'),next=css(value);if(next!==value)originalAttribute.call(element,'style',next);}
          if(element.tagName==='STYLE') {const next=css(element.textContent);if(next!==element.textContent)element.textContent=next;}
        }
      };
      new MutationObserver(records=>{for(const record of records){if(record.type==='attributes')fixTree(record.target);else for(const node of record.addedNodes)fixTree(node);}}).observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['src','poster','style']});
      window.__gwRewriteGrantedURL = rewrite;
    })();
    """#
}
