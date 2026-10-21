// HLSL implicit conversions WE shaders rely on (each line is from a real workshop shader).
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}
uniform float g_AudioSpectrum16Left[16];
uniform float u_Count; // {"material":"count","default":4}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	vec3 color = albedo;
	vec2 radial = 0.0, center = (1.0 - v_TexCoord.xy) * 0.5;
	float pointer = v_TexCoord.zw * 2.0;
	int count = u_Count;
	uint bar = u_Count * 3.0 % 16;
	float level = g_AudioSpectrum16Left[u_Count / 4][bar % 4] + g_AudioSpectrum16Left[pointer];
	vec2 shapeCoord = v_TexCoord.xy;
	shapeCoord.x += shapeCoord.y - 0.5 < 0.0;
	int inside = step(shapeCoord.x, level);
	bool isLeftChannel = shapeCoord.y < 0.49;
	inside *= isLeftChannel;
	level *= shapeCoord.x > 0.0 && shapeCoord.x < 1.0;
	color = mix(albedo, color, 0.5) * level + radial.x + center.y;
	gl_FragColor = vec4(color, float(count + inside) + mix(albedo.a, 1, step(albedo.a, 0)));
}
