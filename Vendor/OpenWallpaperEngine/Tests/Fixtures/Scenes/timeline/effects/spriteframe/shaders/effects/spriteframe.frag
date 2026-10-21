
// Draws the sprite-sheet frame bound to slot 1 over the whole layer, through the frame rect the
// engine gives it: g_Texture1Translation is the frame's origin, g_Texture1Rotation its axes.

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"Sheet"}
uniform vec4 g_Texture1Rotation;
uniform vec2 g_Texture1Translation;

void main() {
	vec2 uv = g_Texture1Translation + v_TexCoord.x * g_Texture1Rotation.xy + v_TexCoord.y * g_Texture1Rotation.zw;
	gl_FragColor = texSample2D(g_Texture1, uv);
}
