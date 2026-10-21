// The face's normal as its colour, or `tint` where its alpha is 1.

uniform vec4 g_Tint; // {"material":"tint","default":"0 0 0 0"}

varying vec3 v_Normal;

void main() {
	gl_FragColor = vec4(mix(v_Normal * 0.5 + 0.5, g_Tint.rgb, g_Tint.a), 1.0);
}
