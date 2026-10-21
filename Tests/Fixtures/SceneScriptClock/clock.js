'use strict';

export var scriptProperties = createScriptProperties()
	// Whether you want a 24h or 12h style format
	.addCheckbox({
		name: 'use24hFormat',
		label: 'ui_editor_properties_use_24h_format',
		value: true
	})
	// Whether you want to see the seconds or not
	.addCheckbox({
		name: 'showSeconds',
		label: 'ui_editor_properties_show_seconds',
		value: false
	})
	// This will be used to separate each element
	.addText({
		name: 'delimiter',
		label: 'ui_editor_properties_delimiter',
		value: ':'
	})
	.finish();

/**
 * @param {String} value (for property 'text')
 */
export function update(value) {
	let time = new Date();
	var hours = time.getHours();
	if (!scriptProperties.use24hFormat) {
		hours %= 12;
		if (hours == 0) {
			hours = 12;
		}
	}
	hours = ("00" + hours).slice(-2);
	let minutes = ("00" + time.getMinutes()).slice(-2);
	value = hours + scriptProperties.delimiter + minutes;
	if (scriptProperties.showSeconds) {
		let seconds = ("00" + time.getSeconds()).slice(-2);
		value += scriptProperties.delimiter + seconds;
	}
	return value;
}
