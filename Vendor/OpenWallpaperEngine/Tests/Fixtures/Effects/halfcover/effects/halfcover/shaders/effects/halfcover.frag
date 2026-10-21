
// The layer's colour at half alpha, blended over the pass's target: what the target held before
// the pass shows through by half (transparent black in a target nothing drew into yet).

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(albedo.rgb, 0.5);
}
