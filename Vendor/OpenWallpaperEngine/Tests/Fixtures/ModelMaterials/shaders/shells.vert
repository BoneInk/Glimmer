// A model shader for the renderer's instancing tests: WE's `fur4` convention (`INSTANCECOUNT`
// instances, `gl_InstanceID / (INSTANCECOUNT - 1)` from 0 to 1), each instance moved 6 units
// along x from -3 to 3, coloured by its normal.

uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec3 a_Normal;
#if HLSL
in uint gl_InstanceID;
#endif

varying vec3 v_Normal;

void main() {
	float shell = CASTF(gl_InstanceID) / (CASTF(INSTANCECOUNT) - 1.0);
	vec3 localPos = a_Position + vec3((shell - 0.5) * 6.0, 0.0, 0.0);
	gl_Position = mul(mul(vec4(localPos, 1.0), g_ModelMatrix), g_ViewProjectionMatrix);
	v_Normal = a_Normal;
}
