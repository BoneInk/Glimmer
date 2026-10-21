// A varying named like an attribute (`a_…`), as the default project dna_fragment's bg shader has.
uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec4 a_TexCloudsCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	a_TexCloudsCoord = a_TexCoord.xyxy * 2.0;
}
