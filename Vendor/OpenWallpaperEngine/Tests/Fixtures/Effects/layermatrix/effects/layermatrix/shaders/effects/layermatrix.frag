
// Shows what the vertex stage read from g_LayerModelMatrix.

varying vec2 v_TexCoord;
varying vec4 v_Layer;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	gl_FragColor = v_Layer + texSample2D(g_Texture0, v_TexCoord) * 0.0;
}
