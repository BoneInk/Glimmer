// A shader defining its own M_PI and log10, which the prelude also provides.
#define M_PI 3.1415926535897932384626433832795

varying vec4 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}

float log10(float x) { return log(x) / 2.302585092994; }

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	gl_FragColor = albedo * log10(1.0 + sin(v_TexCoord.x * M_PI));
}
