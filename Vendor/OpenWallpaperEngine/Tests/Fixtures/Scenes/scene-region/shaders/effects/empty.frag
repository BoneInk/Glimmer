// Fixture shader written for the tests: draws the framebuffer unchanged.
uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}

varying vec2 v_TexCoord;

void main() {
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
