// A workshop-style particle vertex stage for the geometry-emulation render checks.
attribute vec3 a_Position;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_Color;

varying vec4 v_Color;

void main() {
	gl_Position = vec4(a_Position, a_TexCoordVec4.w);
	v_Color = a_Color;
}
