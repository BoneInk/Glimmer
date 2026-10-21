// Fixture shader written for the tests: the layer's quad, with mask coordinates when MASK is on.
uniform mat4 g_ModelViewProjectionMatrix;
#if MASK
uniform vec4 g_Texture1Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	vec2 maskScale = vec2(1.0, 1.0);
#if MASK
	maskScale = g_Texture1Resolution.zw / g_Texture1Resolution.xy;
#endif
	v_TexCoord = vec4(a_TexCoord, a_TexCoord * maskScale);
}
