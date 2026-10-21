// One bar per band of the spectrum, rising from the bottom as tall as the band's level, over the scene
// under the composition layer. Written in WE's dialect (HLSL conversions: a float `%` giving a
// uint index) like the Workshop audio bar effects.
// [COMBO] {"material":"Frequency Resolution","combo":"RESOLUTION","type":"options","default":16,"options":{"16":16,"32":32}}
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}

#include "common.h"
#include "common_blending.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"previous","hidden":true}
uniform vec3 u_BarColor; // {"default":"1 1 1","material":"Bar Color","type":"color"}

#if RESOLUTION == 16
uniform float g_AudioSpectrum16Left[16];
uniform float g_AudioSpectrum16Right[16];
#define u_Left g_AudioSpectrum16Left
#define u_Right g_AudioSpectrum16Right
#endif
#if RESOLUTION == 32
uniform float g_AudioSpectrum32Left[32];
uniform float g_AudioSpectrum32Right[32];
#define u_Left g_AudioSpectrum32Left
#define u_Right g_AudioSpectrum32Right
#endif

void main() {
	float frequency = v_TexCoord.x * RESOLUTION;
	uint band = frequency % RESOLUTION;
	float level = (u_Left[band] + u_Right[band]) * 0.5;
	float bar = step(1.0 - v_TexCoord.y, level);
	vec4 scene = texSample2D(g_Texture0, v_TexCoord);
	vec3 color = ApplyBlending(BLENDMODE, scene.rgb, u_BarColor, bar);
	gl_FragColor = vec4(color, scene.a);
}
