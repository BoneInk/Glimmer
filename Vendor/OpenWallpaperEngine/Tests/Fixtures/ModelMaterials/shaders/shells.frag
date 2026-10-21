// [COMBO] {"material":"ui_editor_properties_fur_quality","combo":"INSTANCECOUNT","default":5,"options":{"ui_editor_properties_low":5,"ui_editor_properties_medium":9,"ui_editor_properties_high":13,"ui_editor_properties_ultra":21}}
// The face's normal as its colour (`shells.vert`).

varying vec3 v_Normal;

void main() {
	gl_FragColor = vec4(v_Normal * 0.5 + 0.5, 1.0);
}
