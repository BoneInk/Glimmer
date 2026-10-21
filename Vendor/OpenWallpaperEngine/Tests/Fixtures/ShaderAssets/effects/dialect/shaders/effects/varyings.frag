// The vertex stage declares v_TexCoord as vec4; this stage reads it as vec2.
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
