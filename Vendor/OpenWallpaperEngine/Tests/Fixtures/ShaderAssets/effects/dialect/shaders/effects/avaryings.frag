uniform sampler2D g_Texture0;
varying vec4 a_TexCloudsCoord;

void main() {
	gl_FragColor = texSample2D(g_Texture0, a_TexCloudsCoord.zw);
}
