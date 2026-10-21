// Names GLSL allows that are C++ (and so MSL) keywords, declared by the shader itself.
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}

float operator(float this) { return this * 2.0; }

void main() {
	vec2 or = v_TexCoord * 0.5;
	float and = operator(or.x);
	gl_FragColor = texSample2D(g_Texture0, or) * and;
}
