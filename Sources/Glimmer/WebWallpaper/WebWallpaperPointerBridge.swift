import Foundation

enum WebWallpaperPointerBridge {
    static let script = #"""
    (() => {
      let hovered = null, pressed = null, captured = null, down = false, lastData = {};
      function send(target, name, data, bubbles = true) {
        if (!target) return true;
        const options = {...data, bubbles, cancelable: true, composed: true};
        const event = name.includes('pointer')
          ? new PointerEvent(name, {...options, pointerId: 1, pointerType: 'mouse', isPrimary: true})
          : name === 'wheel' ? new WheelEvent(name, options) : new MouseEvent(name, options);
        return target.dispatchEvent(event);
      }
      const setCapture = Element.prototype.setPointerCapture;
      const releaseCapture = Element.prototype.releasePointerCapture;
      const hasCapture = Element.prototype.hasPointerCapture;
      Element.prototype.setPointerCapture = function(id) {
        if (id !== 1 || !down) return setCapture.call(this, id);
        captured = this; send(this, 'gotpointercapture', lastData);
      };
      Element.prototype.releasePointerCapture = function(id) {
        if (id !== 1 || captured !== this) return releaseCapture.call(this, id);
        captured = null; send(this, 'lostpointercapture', lastData);
      };
      Element.prototype.hasPointerCapture = function(id) {
        return id === 1 && captured === this || hasCapture.call(this, id);
      };
      window.__gwForwardPointer = input => {
        const x = input.x * innerWidth, y = input.y * innerHeight;
        const target = document.elementFromPoint(x, y);
        const data = {clientX: x, clientY: y, button: 0, buttons: down ? 1 : 0,
          altKey: input.alt, ctrlKey: input.ctrl, shiftKey: input.shift, metaKey: input.meta,
          detail: input.clicks || 0};
        lastData = data;
        if (target !== hovered) {
          send(hovered, 'pointerout', {...data, relatedTarget: target});
          send(hovered, 'mouseout', {...data, relatedTarget: target});
          send(hovered, 'pointerleave', {...data, relatedTarget: target}, false);
          send(hovered, 'mouseleave', {...data, relatedTarget: target}, false);
          send(target, 'pointerover', {...data, relatedTarget: hovered});
          send(target, 'mouseover', {...data, relatedTarget: hovered});
          send(target, 'pointerenter', {...data, relatedTarget: hovered}, false);
          send(target, 'mouseenter', {...data, relatedTarget: hovered}, false);
          hovered = target;
        }
        if (input.kind === 'down') {
          down = true; pressed = target; data.buttons = 1;
          if (send(target, 'pointerdown', data) && send(target, 'mousedown', data)) {
            target?.closest('button,input,textarea,select,a[href],[tabindex]')?.focus({preventScroll: true});
          }
        } else if (input.kind === 'up') {
          data.buttons = 0;
          send(captured || target || pressed, 'pointerup', data);
          send(captured || target || pressed, 'mouseup', data);
          if (down && pressed && target === pressed) {
            send(target, 'click', data);
            if (input.clicks === 2) send(target, 'dblclick', data);
          }
          if (captured) send(captured, 'lostpointercapture', data);
          down = false; pressed = null; captured = null;
        } else if (input.kind === 'wheel') {
          if (send(target, 'wheel', {...data, deltaX: input.dx, deltaY: input.dy, deltaMode: 0})) {
            let scroll = target;
            while (scroll && scroll !== document.documentElement &&
                   scroll.scrollHeight <= scroll.clientHeight && scroll.scrollWidth <= scroll.clientWidth) scroll = scroll.parentElement;
            (scroll || document.scrollingElement)?.scrollBy(input.dx, input.dy);
          }
        } else {
          send(captured || (down ? pressed : target), 'pointermove', data);
          send(captured || (down ? pressed : target), 'mousemove', data);
        }
      };
    })();
    """#
}
