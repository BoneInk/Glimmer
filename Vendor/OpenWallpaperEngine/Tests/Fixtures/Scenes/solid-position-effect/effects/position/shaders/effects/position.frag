// Writes the pixel's a_Position over the framebuffer's resolution into red and green, as
// 3141421197's ray-marcher takes its rays from it: in WE the last pass's positions are the
// layer's quad in layer units (±64 × ±32 here), so red and green ramp across the layer.

varying vec2 v_Position;
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"framebuffer","hidden":true}
uniform vec4 g_Texture0Resolution;

void main() {
	vec2 uv = v_Position / g_Texture0Resolution.xy + 0.5;
	gl_FragColor = vec4(uv, texSample2D(g_Texture0, v_TexCoord).b, 1.0);
}
