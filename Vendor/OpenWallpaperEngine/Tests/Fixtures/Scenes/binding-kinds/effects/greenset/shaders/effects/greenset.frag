// With the GREENSET combo on, writes the `green` constant into green over the layer's colour.

// [COMBO] {"material":"Green set","combo":"GREENSET","type":"options","default":0}

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform float g_Green; // {"material":"green","default":1}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
#if GREENSET == 1
	albedo.g = g_Green;
#endif
	gl_FragColor = albedo;
}
