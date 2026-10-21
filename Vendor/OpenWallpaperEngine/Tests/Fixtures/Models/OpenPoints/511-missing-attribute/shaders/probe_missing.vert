attribute vec3 a_Position;
attribute vec4 a_Color;
attribute vec2 a_TexCoordC1;
uniform mat4 g_ModelViewProjectionMatrix;
varying vec4 v_Color;
varying vec2 v_UV1;
void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_Color = a_Color;
	v_UV1 = a_TexCoordC1;
}
