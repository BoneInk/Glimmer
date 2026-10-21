
// Adds a quarter to red over what the last frame left in the bound buffer.

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec4 last = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(last.r + 0.25, 0, 0, 1);
}
