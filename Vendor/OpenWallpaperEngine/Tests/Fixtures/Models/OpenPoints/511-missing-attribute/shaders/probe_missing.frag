varying vec4 v_Color;
varying vec2 v_UV1;
void main() {
	gl_FragColor = vec4(v_Color.rgb + vec3(v_UV1, 0.0), 1.0);
}
