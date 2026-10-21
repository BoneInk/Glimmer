// A model shader for the renderer's tests: WE's model conventions (`g_ModelMatrix`,
// `g_ViewProjectionMatrix`, row-vector `mul`, `g_Bones` under `SKINNING`), colouring each face by
// its normal.

uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec3 a_Normal;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];

attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

varying vec3 v_Normal;

void main() {
	vec3 localPos = a_Position;
#if SKINNING
	localPos = mul(vec4(localPos, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
					g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
					g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
					g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
#endif
	gl_Position = mul(mul(vec4(localPos, 1.0), g_ModelMatrix), g_ViewProjectionMatrix);
	v_Normal = a_Normal;
}
