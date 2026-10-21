
// Shows the accumulated buffer.

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
