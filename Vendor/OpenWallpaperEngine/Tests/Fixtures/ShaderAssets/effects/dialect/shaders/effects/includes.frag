// Includes only the outer header, which itself includes the inner one it calls.
#include "dialect_outer.h"

varying vec4 v_TexCoord;
uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	gl_FragColor = vec4(Outer(texSample2D(g_Texture0, v_TexCoord.xy).rgb), 1.0);
}
