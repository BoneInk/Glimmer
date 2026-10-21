
// Writes the pixel's u into red over the layer's own colour: a buffer of one texel shows one
// flat colour, a buffer the layer's size a ramp.

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(v_TexCoord.x, albedo.g, albedo.b, albedo.a);
}
