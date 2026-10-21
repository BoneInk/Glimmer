// Writes the `red` constant into red over the layer's own colour.

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform float g_Red; // {"material":"red","default":0}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(g_Red, albedo.g, albedo.b, albedo.a);
}
