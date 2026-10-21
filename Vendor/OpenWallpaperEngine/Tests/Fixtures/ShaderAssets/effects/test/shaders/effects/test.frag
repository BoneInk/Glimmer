#include "common.h"

varying vec2 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	float wave = sin(v_TexCoord.x * M_PI_2);
	albedo.a = max(0, pow(albedo.a, 4) * wave);
	gl_FragColor = albedo;
}
