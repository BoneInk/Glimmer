// Original utility implementation against Wallpaper Engine's public module
// signatures. Evaluate this expression once, then supply the worker's own vector
// constructors. No host objects, asset paths or native capabilities are exposed.
(function (Vec2, Vec3) {
    'use strict';
    const deg2rad = Math.PI / 180;
    const rad2deg = 180 / Math.PI;
    const WEMath = Object.freeze({
        deg2rad,
        rad2deg,
        smoothStep(min, max, value) {
            // Equal edges are not specified by the public API. This runtime
            // chooses a finite step, inclusive at the edge, instead of 0/0.
            if (min === max) return value < min ? 0 : 1;
            const t = Math.max(0, Math.min(1, (value - min) / (max - min)));
            return t * t * (3 - 2 * t);
        },
        mix(a, b, value) { return a + (b - a) * value; }
    });
    const WEColor = Object.freeze({
        rgb2hsv(rgb) {
            const r = rgb.x, g = rgb.y, b = rgb.z;
            const hi = Math.max(r, g, b), lo = Math.min(r, g, b), delta = hi - lo;
            let hue = 0;
            if (delta !== 0) {
                if (hi === r) hue = (g - b) / delta + (g < b ? 6 : 0);
                else if (hi === g) hue = (b - r) / delta + 2;
                else hue = (r - g) / delta + 4;
                hue /= 6;
            }
            return new Vec3(hue, hi === 0 ? 0 : delta / hi, hi);
        },
        hsv2rgb(hsv) {
            // The normalized documented domain is [0,1]. Periodic hue outside
            // it is an explicit local convention, not verified Windows parity.
            const hue = hsv.x - Math.floor(hsv.x), saturation = hsv.y, value = hsv.z;
            const sector = hue * 6, index = Math.floor(sector), f = sector - index;
            const p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f));
            switch (index) {
            case 0: return new Vec3(value, t, p);
            case 1: return new Vec3(q, value, p);
            case 2: return new Vec3(p, value, t);
            case 3: return new Vec3(p, q, value);
            case 4: return new Vec3(t, p, value);
            case 5: return new Vec3(value, p, q);
            default: return new Vec3(NaN, NaN, NaN);
            }
        },
        normalizeColor(rgb) { return new Vec3(rgb.x / 255, rgb.y / 255, rgb.z / 255); },
        expandColor(rgb) { return new Vec3(rgb.x * 255, rgb.y * 255, rgb.z * 255); }
    });
    const WEVector = Object.freeze({
        // Public docs specify degrees, but do not fix axis orientation or angle
        // output range. Use mathematical +X toward +Y and atan2 [-180,180].
        angleVector2(angle) {
            const radians = angle * deg2rad;
            return new Vec2(Math.cos(radians), Math.sin(radians));
        },
        vectorAngle2(direction) { return Math.atan2(direction.y, direction.x) * rad2deg; }
    });
    return Object.freeze({ WEMath, WEColor, WEVector });
})
