// Fixture shader written for the tests: mixes a colour over the layer through WE's blend
// helpers, with the uniform names and combos the tint effect's material uses.
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":30}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform float g_BlendAlpha; // {"material":"alpha","label":"ui_editor_properties_alpha","default":1,"range":[0,1]}
uniform vec3 g_TintColor; // {"material":"color","label":"ui_editor_properties_color","type":"color","default":"1 0 0"}

void main() {
	vec4 color = texSample2D(g_Texture0, v_TexCoord.xy);
	float amount = g_BlendAlpha;
#if MASK
	amount = amount * texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif
	color.rgb = ApplyBlending(BLENDMODE, color.rgb, g_TintColor, amount);
#if BLENDMODE == 0
	color.a = 1.0;
#endif
	gl_FragColor = color;
}
