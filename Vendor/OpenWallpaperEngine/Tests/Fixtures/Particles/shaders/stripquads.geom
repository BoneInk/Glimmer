// Emits `size / 10` quads (a runtime count, at most 3) side by side along x, 20 units wide with
// a 20-unit gap, each its own strip. The declared bound is higher than anything it emits.
uniform mat4 g_ModelViewProjectionMatrix;

in vec4 v_Color;
in vec4 gl_Position;

out vec4 v_Color;
out vec4 gl_Position;

PS_INPUT corner(vec3 centre, vec2 offset, vec4 color)
{
	PS_INPUT v;
	v.gl_Position = mul(vec4(centre + vec3(offset, 0.0), 1.0), g_ModelViewProjectionMatrix);
	v.v_Color = color;
	return v;
}

[maxvertexcount(16)]
void main() {
	int quads = int(IN[0].gl_Position.w / 10.0);
	for (int q = 0; q < quads; ++q) {
		vec3 centre = IN[0].gl_Position.xyz + vec3(float(q) * 40.0, 0.0, 0.0);
		OUT.Append(corner(centre, vec2(-10.0, -10.0), IN[0].v_Color));
		OUT.Append(corner(centre, vec2(-10.0, 10.0), IN[0].v_Color));
		OUT.Append(corner(centre, vec2(10.0, -10.0), IN[0].v_Color));
		OUT.Append(corner(centre, vec2(10.0, 10.0), IN[0].v_Color));
		OUT.RestartStrip();
	}
}
