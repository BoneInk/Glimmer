import Foundation

/// A starting point for a common script, as WE's editor offers when a script is added.
public struct SceneScriptTemplate: Hashable, Sendable, Identifiable {
    public enum ID: String, CaseIterable, Sendable {
        case empty, clockText, dateText, audioScale, cursorFollow, objectScript
    }

    public let id: ID
    /// The fields it is written for (empty: any).
    public let fields: Set<String>
    public let source: String

    /// The templates offered for `field` (an object field name, or an effect's `visible`).
    public static func templates(for field: String) -> [SceneScriptTemplate] {
        all.filter { $0.fields.isEmpty || $0.fields.contains(field) }
    }

    public static func template(_ id: ID) -> SceneScriptTemplate {
        all.first { $0.id == id }!
    }

    public static let all: [SceneScriptTemplate] = [
        SceneScriptTemplate(id: .empty, fields: [], source: """
            'use strict';

            /**
             * @param {*} value - the property's current value
             * @return {*} the new value
             */
            export function update(value) {
            \treturn value;
            }

            """),
        SceneScriptTemplate(id: .clockText, fields: ["text"], source: """
            'use strict';

            export var scriptProperties = createScriptProperties()
            \t.addCheckbox({ name: 'use24h', label: '24-hour clock', value: true })
            \t.addCheckbox({ name: 'showSeconds', label: 'Show seconds', value: false })
            \t.finish();

            function pad(number) {
            \treturn number < 10 ? '0' + number : String(number);
            }

            /**
             * @param {String} value - the text the layer shows
             * @return {String} the current time
             */
            export function update(value) {
            \tconst now = new Date();
            \tlet hours = now.getHours();
            \tlet suffix = '';
            \tif (!scriptProperties.use24h) {
            \t\tsuffix = hours < 12 ? ' AM' : ' PM';
            \t\thours = hours % 12 || 12;
            \t}
            \tlet text = pad(hours) + ':' + pad(now.getMinutes());
            \tif (scriptProperties.showSeconds) {
            \t\ttext += ':' + pad(now.getSeconds());
            \t}
            \treturn text + suffix;
            }

            """),
        SceneScriptTemplate(id: .dateText, fields: ["text"], source: """
            'use strict';

            export var scriptProperties = createScriptProperties()
            \t.addCombo({ name: 'style', label: 'Style', options: [
            \t\t{ label: 'Long', value: 'long' },
            \t\t{ label: 'Short', value: 'short' },
            \t\t{ label: 'Numeric', value: 'numeric' }
            \t] })
            \t.finish();

            /**
             * @param {String} value - the text the layer shows
             * @return {String} today's date
             */
            export function update(value) {
            \tconst now = new Date();
            \tif (scriptProperties.style === 'numeric') {
            \t\treturn now.toLocaleDateString();
            \t}
            \treturn now.toLocaleDateString(undefined, {
            \t\tweekday: scriptProperties.style === 'long' ? 'long' : undefined,
            \t\tyear: 'numeric',
            \t\tmonth: scriptProperties.style,
            \t\tday: 'numeric'
            \t});
            }

            """),
        SceneScriptTemplate(id: .audioScale, fields: ["scale"], source: """
            'use strict';

            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'strength', label: 'Strength', value: 0.5, min: 0, max: 2 })
            \t.addSlider({ name: 'smoothing', label: 'Smoothing', value: 0.8, min: 0, max: 0.99 })
            \t.finish();

            // Audio buffers can only be registered at global scope.
            const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
            let level = 0;
            let base;

            /**
             * @param {Vec3} value - the layer's scale
             */
            export function init(value) {
            \tbase = value.copy();
            \treturn value;
            }

            /**
             * @param {Vec3} value - the layer's scale
             * @return {Vec3} the scale, larger with the bass
             */
            export function update(value) {
            \t// The lowest bands of both channels: the bass.
            \tconst bass = (audio.average[0] + audio.average[1] + audio.average[2]) / 3;
            \tlevel = level * scriptProperties.smoothing + bass * (1 - scriptProperties.smoothing);
            \treturn base.multiply(1 + level * scriptProperties.strength);
            }

            """),
        SceneScriptTemplate(id: .cursorFollow, fields: ["origin"], source: """
            'use strict';

            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'speed', label: 'Speed', value: 4, min: 0.1, max: 20 })
            \t.finish();

            /**
             * @param {Vec3} value - the layer's position
             * @return {Vec3} the position, easing towards the cursor
             */
            export function update(value) {
            \tconst target = input.cursorWorldPosition;
            \tconst amount = Math.min(1, engine.frametime * scriptProperties.speed);
            \tvalue.x += (target.x - value.x) * amount;
            \tvalue.y += (target.y - value.y) * amount;
            \treturn value;
            }

            """),
        SceneScriptTemplate(id: .objectScript, fields: ["visible"], source: """
            'use strict';

            /**
             * Runs once when the layer is created.
             */
            export function init(value) {
            \treturn value;
            }

            /**
             * Runs every frame. Change any member of thisLayer here, e.g. thisLayer.alpha.
             * @param {Boolean} value - whether the layer is visible
             * @return {Boolean}
             */
            export function update(value) {
            \treturn value;
            }

            /**
             * Runs when the user changes a property.
             */
            export function applyUserProperties(changedUserProperties) {
            }

            """),
    ]
}
