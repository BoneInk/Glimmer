
// Reads the layer's scale back from its object matrix, as Workshop effects do.

uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_LayerModelMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec4 v_Layer;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord;
	vec2 right = vec2(g_LayerModelMatrix[0][0], g_LayerModelMatrix[0][1]);
	vec2 up = vec2(g_LayerModelMatrix[1][0], g_LayerModelMatrix[1][1]);
	v_Layer = vec4(length(right) / 4.0, length(up) / 4.0, g_LayerModelMatrix[3][0] / 1000.0, 1.0);
}
