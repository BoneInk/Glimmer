import Foundation

/// A whole script the script editor's Snippets › Replace Script menu puts in place of the draft
/// (WE's `ui_editor_script_snippet_*`). WE's editor reads each from its install
/// (`ui/dist/monaco/snippets/<file>.js`); the app hands those in when the user's WE copy has them
/// (`WallpaperEditorServices.scriptSnippet`), and otherwise this project's own script, written
/// for the same field, does the same job. Click Wiggle and Cursor Avoid have no file in WE 2.8.42.
public struct SceneScriptSnippet: Hashable, Sendable, Identifiable {
    public enum ID: String, CaseIterable, Sendable {
        case rainbowColor, flicker, dragDrop, clickPlaySound, rotation, rotationPivot, screenBounce, audioFactor
        case clickWiggle, cursorAvoid, cursorFollow
    }

    /// The kind of field a snippet is written for, which WE's menu shows beside it.
    public enum Field: String, Sendable {
        case color, number, origin, angles, layer
    }

    public let id: ID
    /// WE's snippet file (`ui/dist/monaco/snippets/<file>.js`); nil when WE ships none.
    public let weFile: String?
    public let field: Field
    /// This project's script for it.
    public let source: String

    /// The menu's snippets, in WE's order (`openSnippetMenu`), then the ones WE names but doesn't ship.
    public static let all: [SceneScriptSnippet] = [
        SceneScriptSnippet(id: .rainbowColor, weFile: "script_vec3_color_rainbow", field: .color, source: Sources.rainbowColor),
        SceneScriptSnippet(id: .flicker, weFile: "script_flicker_value", field: .number, source: Sources.flicker),
        SceneScriptSnippet(id: .dragDrop, weFile: "script_origin_drag_drop", field: .origin, source: Sources.dragDrop),
        SceneScriptSnippet(id: .clickPlaySound, weFile: "script_layer_click_to_play", field: .layer, source: Sources.clickPlaySound),
        SceneScriptSnippet(id: .rotation, weFile: "script_angles_rotation", field: .angles, source: Sources.rotation),
        SceneScriptSnippet(id: .rotationPivot, weFile: "script_angles_rotation_pivot", field: .angles, source: Sources.rotationPivot),
        SceneScriptSnippet(id: .screenBounce, weFile: "script_origin_reflect", field: .origin, source: Sources.screenBounce),
        SceneScriptSnippet(id: .audioFactor, weFile: "script_factor_audio_response", field: .number, source: Sources.audioFactor),
        SceneScriptSnippet(id: .clickWiggle, weFile: nil, field: .angles, source: Sources.clickWiggle),
        SceneScriptSnippet(id: .cursorAvoid, weFile: nil, field: .origin, source: Sources.cursorAvoid),
        SceneScriptSnippet(id: .cursorFollow, weFile: nil, field: .origin, source: SceneScriptTemplate.template(.cursorFollow).source),
    ]

    public static func snippet(_ id: ID) -> SceneScriptSnippet {
        all.first { $0.id == id }!
    }

    /// The script to use: WE's own when `weSource` has it (non-empty), else this project's.
    public func resolvedSource(weSource: (String) -> String?) -> String {
        if let weFile, let text = weSource(weFile), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return source
    }

    /// The scripts, written for this project against SceneScript's documented API.
    enum Sources {
        static let rainbowColor = """
            'use strict';

            import * as WEColor from 'WEColor';

            /** Bind to a colour: it cycles through the hues. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'speed', label: 'Cycles per second', value: 0.1, min: 0, max: 2, integer: false })
            \t.addSlider({ name: 'saturation', label: 'Saturation', value: 1, min: 0, max: 1, integer: false })
            \t.addSlider({ name: 'brightness', label: 'Brightness', value: 1, min: 0, max: 1, integer: false })
            \t.finish();

            let hue = 0;

            /**
             * @param {Vec3} value - the colour
             * @return {Vec3} the colour at the current hue
             */
            export function update(value) {
            \thue = (hue + engine.frametime * scriptProperties.speed) % 1;
            \treturn WEColor.hsv2rgb(new Vec3(hue, scriptProperties.saturation, scriptProperties.brightness));
            }

            """

        static let flicker = """
            'use strict';

            /** Bind to a number (an opacity, an effect's strength): it flickers around its value. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'rate', label: 'Changes per second', value: 10, min: 1, max: 30, integer: false })
            \t.addSlider({ name: 'low', label: 'Lowest', value: 0.6, min: 0, max: 1, integer: false })
            \t.addSlider({ name: 'high', label: 'Highest', value: 1, min: 0, max: 2, integer: false })
            \t.addSlider({ name: 'softness', label: 'Softness', value: 0.5, min: 0, max: 1, integer: false })
            \t.finish();

            let base = 1;
            let from = 1;
            let to = 1;
            let elapsed = 0;

            function next() {
            \treturn scriptProperties.low + Math.random() * (scriptProperties.high - scriptProperties.low);
            }

            /**
             * @param {Number} value - the field's value
             */
            export function init(value) {
            \tbase = value;
            \tfrom = to = next();
            \treturn value;
            }

            /**
             * @param {Number} value - the field's value
             * @return {Number} the value scaled by the flicker
             */
            export function update(value) {
            \tconst period = 1 / scriptProperties.rate;
            \telapsed += engine.frametime;
            \tif (elapsed >= period) {
            \t\telapsed %= period;
            \t\tfrom = to;
            \t\tto = next();
            \t}
            \tconst t = Math.min(1, elapsed / (period * Math.max(scriptProperties.softness, 0.001)));
            \treturn base * (from + (to - from) * t);
            }

            """

        static let dragDrop = """
            'use strict';

            /** Bind to a layer's position: drag the layer with the mouse. */
            let dragging = false;
            let grab = new Vec3(0, 0, 0);

            /**
             * @param {CursorEvent} event
             */
            export function cursorDown(event) {
            \tdragging = true;
            \tgrab = thisLayer.origin.subtract(input.cursorWorldPosition);
            }

            /**
             * @param {CursorEvent} event
             */
            export function cursorUp(event) {
            \tdragging = false;
            }

            /**
             * @param {Vec3} value - the layer's position
             * @return {Vec3} the position under the cursor while dragging
             */
            export function update(value) {
            \tif (dragging && !input.cursorLeftDown) {
            \t\tdragging = false;
            \t}
            \tif (!dragging) {
            \t\treturn value;
            \t}
            \tconst cursor = input.cursorWorldPosition.add(grab);
            \treturn new Vec3(cursor.x, cursor.y, value.z);
            }

            """

        static let clickPlaySound = """
            'use strict';

            /** Add to a layer: clicking it plays a sound layer. */
            export var scriptProperties = createScriptProperties()
            \t.addText({ name: 'sound', label: 'Sound layer name', value: 'Sound' })
            \t.addCheckbox({ name: 'restart', label: 'Restart while playing', value: true })
            \t.finish();

            /**
             * @param {CursorEvent} event
             */
            export function cursorClick(event) {
            \tconst sound = thisScene.getLayer(scriptProperties.sound);
            \tif (!sound) {
            \t\tconsole.error('No layer named ' + scriptProperties.sound);
            \t\treturn;
            \t}
            \tif (sound.isPlaying()) {
            \t\tif (!scriptProperties.restart) return;
            \t\tsound.stop();
            \t}
            \tsound.play();
            }

            """

        static let rotation = """
            'use strict';

            /** Bind to a layer's rotation: it turns at a steady speed. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'speed', label: 'Degrees per second', value: 45, min: -360, max: 360, integer: false })
            \t.finish();

            /**
             * @param {Vec3} value - the rotation in degrees
             * @return {Vec3} the rotation, turned a little further
             */
            export function update(value) {
            \tvalue.z = (value.z + engine.frametime * scriptProperties.speed) % 360;
            \treturn value;
            }

            """

        static let rotationPivot = """
            'use strict';

            /** Bind to a layer's rotation: it turns around a pivot point, moving as it turns. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'speed', label: 'Degrees per second', value: 30, min: -360, max: 360, integer: false })
            \t.addSlider({ name: 'pivotX', label: 'Pivot X (layer units)', value: 0, min: -1000, max: 1000, integer: false })
            \t.addSlider({ name: 'pivotY', label: 'Pivot Y (layer units)', value: -100, min: -1000, max: 1000, integer: false })
            \t.finish();

            let start;
            let turned = 0;

            /**
             * @param {Vec3} value - the rotation in degrees
             */
            export function init(value) {
            \tstart = thisLayer.origin.copy();
            \treturn value;
            }

            /**
             * @param {Vec3} value - the rotation in degrees
             * @return {Vec3} the rotation; the position follows the pivot
             */
            export function update(value) {
            \tturned = (turned + engine.frametime * scriptProperties.speed) % 360;
            \tconst radians = turned * Math.PI / 180;
            \tconst pivot = new Vec3(start.x + scriptProperties.pivotX, start.y + scriptProperties.pivotY, start.z);
            \tconst dx = start.x - pivot.x;
            \tconst dy = start.y - pivot.y;
            \tconst cos = Math.cos(radians);
            \tconst sin = Math.sin(radians);
            \tthisLayer.origin = new Vec3(pivot.x + dx * cos - dy * sin, pivot.y + dx * sin + dy * cos, start.z);
            \treturn new Vec3(value.x, value.y, turned);
            }

            """

        static let screenBounce = """
            'use strict';

            /** Bind to a layer's position: it moves and bounces off the edges of the wallpaper. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'speed', label: 'Speed', value: 120, min: 0, max: 1000, integer: false })
            \t.finish();

            let velocity;

            /**
             * @param {Vec3} value - the layer's position
             */
            export function init(value) {
            \tconst angle = (Math.random() * 4 + 0.5) * Math.PI / 2;
            \tvelocity = new Vec3(Math.cos(angle), Math.sin(angle), 0);
            \treturn value;
            }

            /**
             * @param {Vec3} value - the layer's position
             * @return {Vec3} the position, kept inside the wallpaper
             */
            export function update(value) {
            \tconst halfWidth = thisLayer.size.x * thisLayer.scale.x / 2;
            \tconst halfHeight = thisLayer.size.y * thisLayer.scale.y / 2;
            \tconst canvas = engine.canvasSize;
            \tvalue = value.add(velocity.multiply(scriptProperties.speed * engine.frametime));
            \tif (value.x < halfWidth || value.x > canvas.x - halfWidth) {
            \t\tvelocity.x = -velocity.x;
            \t\tvalue.x = Math.min(Math.max(value.x, halfWidth), canvas.x - halfWidth);
            \t}
            \tif (value.y < halfHeight || value.y > canvas.y - halfHeight) {
            \t\tvelocity.y = -velocity.y;
            \t\tvalue.y = Math.min(Math.max(value.y, halfHeight), canvas.y - halfHeight);
            \t}
            \treturn value;
            }

            """

        static let audioFactor = """
            'use strict';

            /** Bind to a number: it grows with the music. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'strength', label: 'Strength', value: 1, min: 0, max: 5, integer: false })
            \t.addSlider({ name: 'smoothing', label: 'Smoothing', value: 0.75, min: 0, max: 0.99, integer: false })
            \t.addCombo({ name: 'band', label: 'Frequencies', options: [
            \t\t{ label: 'Bass', value: 'bass' },
            \t\t{ label: 'Mids', value: 'mids' },
            \t\t{ label: 'Highs', value: 'highs' },
            \t\t{ label: 'All', value: 'all' }
            \t] })
            \t.finish();

            // Audio buffers can only be registered at global scope.
            const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
            const ranges = { bass: [0, 3], mids: [4, 9], highs: [10, 15], all: [0, 15] };
            let level = 0;
            let base = 0;

            /**
             * @param {Number} value - the field's value
             */
            export function init(value) {
            \tbase = value;
            \treturn value;
            }

            /**
             * @param {Number} value - the field's value
             * @return {Number} the value plus the music's level
             */
            export function update(value) {
            \tconst range = ranges[scriptProperties.band] || ranges.all;
            \tlet sum = 0;
            \tfor (let band = range[0]; band <= range[1]; ++band) {
            \t\tsum += audio.average[band];
            \t}
            \tconst current = sum / (range[1] - range[0] + 1);
            \tlevel = level * scriptProperties.smoothing + current * (1 - scriptProperties.smoothing);
            \treturn base + level * scriptProperties.strength;
            }

            """

        static let clickWiggle = """
            'use strict';

            /** Bind to a layer's rotation: clicking the layer makes it wiggle and settle. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'angle', label: 'Wiggle (degrees)', value: 12, min: 0, max: 90, integer: false })
            \t.addSlider({ name: 'speed', label: 'Wiggles per second', value: 4, min: 0.5, max: 20, integer: false })
            \t.addSlider({ name: 'duration', label: 'Duration (seconds)', value: 1, min: 0.1, max: 5, integer: false })
            \t.finish();

            let rest;
            let time = -1;

            /**
             * @param {Vec3} value - the rotation in degrees
             */
            export function init(value) {
            \trest = value.copy();
            \treturn value;
            }

            /**
             * @param {CursorEvent} event
             */
            export function cursorClick(event) {
            \ttime = 0;
            }

            /**
             * @param {Vec3} value - the rotation in degrees
             * @return {Vec3} the rotation, swinging while the wiggle lasts
             */
            export function update(value) {
            \tif (time < 0) {
            \t\treturn value;
            \t}
            \ttime += engine.frametime;
            \tconst fade = 1 - time / scriptProperties.duration;
            \tif (fade <= 0) {
            \t\ttime = -1;
            \t\treturn rest.copy();
            \t}
            \tconst swing = Math.sin(time * scriptProperties.speed * 2 * Math.PI) * scriptProperties.angle * fade;
            \treturn new Vec3(rest.x, rest.y, rest.z + swing);
            }

            """

        static let cursorAvoid = """
            'use strict';

            /** Bind to a layer's position: it moves away from the cursor and drifts back. */
            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'radius', label: 'Radius', value: 250, min: 10, max: 1000, integer: false })
            \t.addSlider({ name: 'distance', label: 'Distance', value: 120, min: 0, max: 1000, integer: false })
            \t.addSlider({ name: 'ease', label: 'Speed', value: 6, min: 0.5, max: 30, integer: false })
            \t.finish();

            let home;
            let offset = new Vec3(0, 0, 0);

            /**
             * @param {Vec3} value - the layer's position
             */
            export function init(value) {
            \thome = value.copy();
            \treturn value;
            }

            /**
             * @param {Vec3} value - the layer's position
             * @return {Vec3} the position, pushed away from the cursor
             */
            export function update(value) {
            \tconst away = home.subtract(input.cursorWorldPosition);
            \taway.z = 0;
            \tconst length = away.length();
            \tlet target = new Vec3(0, 0, 0);
            \tif (length > 0 && length < scriptProperties.radius) {
            \t\ttarget = away.normalize().multiply(scriptProperties.distance * (1 - length / scriptProperties.radius));
            \t}
            \tconst amount = Math.min(1, engine.frametime * scriptProperties.ease);
            \toffset = offset.add(target.subtract(offset).multiply(amount));
            \treturn home.add(offset);
            }

            """
    }
}
