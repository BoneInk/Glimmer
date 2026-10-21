import XCTest
@testable import OpenWallpaperEngine

/// The HLSL front end's typed rules (`HLSLConversionPass`, `HLSLFrontEnd`): WE compiles its
/// shaders with FXC, so each implicit conversion HLSL makes becomes an explicit GLSL constructor.
/// The cases come from WE's own shaders and Workshop effects in the comparison suite.
final class HLSLFrontEndTests: XCTestCase {
    private func convert(_ text: String) -> String {
        HLSLFrontEnd.afterPreprocess(text)
    }

    /// Initialisers convert to the declared type: a scalar splats, a wider vector truncates; a
    /// loop's initialiser too. Globals keep constant initialisers.
    func testInitialisersConvertToTheDeclaredType() {
        let out = convert("in vec4 d;\nvoid main() {\n vec2 a = 0.0, b, c = d.xyz;\n float f = d;\n for (int i = 1.5; i < 3; i++) {}\n}")
        XCTAssertTrue(out.contains("vec2 a = vec2(0.0), b, c = vec2(d.xyz);"), out)
        XCTAssertTrue(out.contains("float f = float(d);"), out)
        XCTAssertTrue(out.contains("for (int i = int(1.5);"), out)
        let global = "const vec3 k = vec3(1.0);\nvec2 g = vec2(0.0);\n"
        XCTAssertEqual(convert(global), global)
    }

    /// `effects/cloudmotion`: `v_NoiseCoord = v_TexCoord;` assigns a `vec4` to a `vec2`, which
    /// HLSL truncates.
    func testAssignmentTruncatesAWiderVector() {
        let out = convert("in vec4 v_TexCoord;\nout vec2 v_NoiseCoord;\nvoid main() { v_NoiseCoord = v_TexCoord; }")
        XCTAssertTrue(out.contains("v_NoiseCoord = vec2(v_TexCoord);"), out)
    }

    /// Workshop iris effect: `v_PointerUV * (g_Scale * k)` multiplies a `vec4` by a `vec2`, a
    /// `vec2` in HLSL; same-size operands are untouched.
    func testOperandsOfDifferentSizesTruncateToTheNarrower() {
        let out = convert("""
        uniform vec2 scale; in vec3 v_uv; uniform float u;
        void main() {
         vec4 p = vec4(1.0);
         vec2 a = p * scale * 0.5; vec2 b = abs(v_uv - (vec2(u))); vec4 c = p * u + p; vec2 d = p.xy * scale;
        }
        """)
        XCTAssertTrue(out.contains("vec2 a = vec2(p) * scale * 0.5;"), out)
        XCTAssertTrue(out.contains("abs(vec2(v_uv) - (vec2(u)))"), out)
        XCTAssertTrue(out.contains("vec4 c = p * u + p;"), out)
        XCTAssertTrue(out.contains("vec2 d = p.xy * scale;"), out)
    }

    /// `%` is `fmod` on floats; a float subscript truncates; `float x[4n]` indexed twice is packed
    /// `float4`s.
    func testModuloAndSubscriptsFollowHLSL() {
        let out = convert("uniform float g[64]; uniform float s[8];\nvoid main() { float a = 1.0; int i = 2; float x = a % 4.0; float y = s[a / 4.0]; float z = s[i]; float v = g[a][i]; int m = i % 3; }")
        XCTAssertTrue(out.contains("weMod(a , 4.0)"), out)
        XCTAssertTrue(out.contains("s[int(a / 4.0)]"), out)
        XCTAssertTrue(out.contains("float z = s[i];"), out)
        XCTAssertTrue(out.contains("g[int(int(a)) * 4 + int(i)]"), out)
        XCTAssertTrue(out.contains("int m = i % 3;"), out)
    }

    /// HLSL tests a number against zero: `mask = INVERT ? 1 - mask : mask` with the combo
    /// preprocessed to `0` (a Workshop sharpen effect), `if (f)`, `!f`, `a && f`.
    func testNumbersTestedAsConditionsBecomeBool() {
        let out = convert("void main() { float m = 0.0; int k = 1; bool b = true; m = 0 ? 1.0 - m : m; if (m) { m = 1.0; } b = !k && m; }")
        XCTAssertTrue(out.contains("m = bool(0) ? 1.0 - m : m;"), out)
        XCTAssertTrue(out.contains("if (bool(m))"), out)
        XCTAssertTrue(out.contains("b = !bool(k) && bool(m);"), out)
    }

    /// Returns convert to the function's type; compound assignments convert their value, and an
    /// int result of float arithmetic converts back (Simple Audio Bars' circle and centre shapes
    /// multiply an int by a bool).
    func testReturnsAndCompoundAssignmentsConvertLikeHLSL() {
        let out = convert("""
        vec3 f(vec2 uv) {
         vec4 col = vec4(uv, 0.0, 1.0);
         return col;
        }
        void main() {
         int bar = 1; bool left = true; float level = 1.0; vec2 uv = vec2(0.0); vec4 c = vec4(0.0);
         bar *= level * 0.5; level *= left; uv += 1.0; bar *= left; uv += c;
        }
        """)
        XCTAssertTrue(out.contains("return vec3(col);"), out)
        XCTAssertTrue(out.contains("bar = int(bar * ( level * 0.5));"), out)
        XCTAssertTrue(out.contains("level *= float(left);"), out)
        XCTAssertTrue(out.contains("uv += 1.0;"), out)
        XCTAssertTrue(out.contains("bar *= int(left);"), out)
        XCTAssertTrue(out.contains("uv += vec2(c);"), out)
    }

    /// Arguments convert to their parameter's type, choosing the overload HLSL would; `out`
    /// arguments are left alone. Intrinsics bring their arguments to one type: `pow(v, 2)` splats,
    /// `mix` truncates its wider operand.
    func testArgumentsConvertToTheirParameters() {
        let out = convert("""
        struct VS_OUTPUT { vec4 p; };
        vec3 f(vec2 a, out vec3 b, in VS_OUTPUT c, float d) { b = vec3(a, d); return b; }
        void main() { vec4 v = vec4(0.0); vec3 b; VS_OUTPUT o; f(v.xyzw, b, o, 1); vec3 c = pow(b, 2); vec3 l = mix(v, b, 0.5); }
        """)
        XCTAssertTrue(out.contains("f(vec2(v.xyzw), b, o, 1);"), out)
        XCTAssertTrue(out.contains("pow(b, vec3(2))"), out)
        XCTAssertTrue(out.contains("mix(vec3(v), b, 0.5)"), out)
    }

    /// `mul(v, M)` is `M * v` for WE's matrices; `mul(M, v)` is `v * M`; a wider vector
    /// truncates; two vectors make a dot product.
    func testMulSwapsTruncatesAndDots() {
        let out = convert("uniform mat4 M; uniform mat3 N;\nvoid main() { vec4 p = vec4(1.0); vec3 n = vec3(0.0); vec4 a = mul(p, M); vec3 b = mul(N, n); vec3 c = mul(p, N); float d = mul(n, p); }")
        XCTAssertTrue(out.contains("vec4 a = ((M) * (p));"), out)
        XCTAssertTrue(out.contains("vec3 b = ((n) * (N));"), out)
        XCTAssertTrue(out.contains("vec3 c = ((N) * (vec3(p)));"), out)
        XCTAssertTrue(out.contains("float d = dot(n, vec3(p));"), out)
    }

    /// A `mul` the typed pass can't reach still swaps, as WE's `mul` did as a macro.
    func testUntypedMulStillSwaps() {
        XCTAssertEqual(HLSLFrontEnd.expandRemainingMul("x = mul(a, mul(b, c));"), "x = ((((c) * (b))) * (a));")
        let own = "vec2 mul(vec2 a, float b) { return a * b; }\nvoid main() { x = mul(a, b); }"
        XCTAssertEqual(HLSLFrontEnd.expandRemainingMul(own), own, "a shader's own mul stays a call")
    }

    /// HLSL compares vectors component by component; GLSL's operators want scalars. HLSL also
    /// swizzles scalars.
    func testVectorComparisonsAndScalarSwizzles() {
        let out = convert("void main() { vec3 c = vec3(0.0); vec4 p = vec4(1.0); float f = 1.0; bvec3 b = c < p; vec3 s = f.xxx; float t = f.x; }")
        XCTAssertTrue(out.contains("bvec3 b = lessThan(c , vec3(p));"), out)
        XCTAssertTrue(out.contains("vec3 s = vec3(f);"), out)
        XCTAssertTrue(out.contains("float t = f;"), out)
    }

    /// Names it can't type are left as written.
    func testUnknownTypesAreLeftAlone() {
        let text = "void main() { x = a * b.y + c; y = g(1.0) * v; }"
        XCTAssertEqual(convert(text), text)
    }

    /// `for (int s = …) { float s = …; }`: HLSL scopes the loop variable outside the body.
    func testLoopBodyRedeclaringTheLoopVariableGetsItsOwnScope() {
        let text = "for (int s = 0; s < 2; ++s) { float a = float(s); float s = a * 2.0; b += s; }"
        XCTAssertEqual(HLSLFrontEnd.loopBodyScopes(text),
                       "for (int s = 0; s < 2; ++s) { float a = float(s); float s_weBody = a * 2.0; b += s_weBody; }")
    }

    /// Only a declaration directly in the body is the body's own: one in a nested block already
    /// has a scope of its own (GLSL allows it), and a nested loop's header belongs to that loop.
    /// Members (`p.s`, `p . s`) keep their names; any scalar, vector or matrix type declares.
    func testLoopBodyScopesTakeOnlyTheBodysOwnDeclaration() {
        let nested = "for (int s = 0; s < 2; ++s) { if (s > 0) { float s = 1.0; a += s; } b += s; }"
        XCTAssertEqual(HLSLFrontEnd.loopBodyScopes(nested), nested)
        let header = "for (int s = 0; s < 2; ++s) { for (float s = 0.0; s < 1.0; s += 0.5) { a += s; } }"
        XCTAssertEqual(HLSLFrontEnd.loopBodyScopes(header), header)
        XCTAssertEqual(HLSLFrontEnd.loopBodyScopes("for (int s = 0; s < 2; ++s) { mat2x3 s = m; a = p.s + p . s + s[0].x; }"),
                       "for (int s = 0; s < 2; ++s) { mat2x3 s_weBody = m; a = p.s + p . s + s_weBody[0].x; }")
        XCTAssertEqual(HLSLFrontEnd.loopBodyScopes("for(uint s=0u;s<2u;s++){\n  bvec2 s =\n b;\n}"),
                       "for(uint s=0u;s<2u;s++){\n  bvec2 s_weBody =\n b;\n}")
        // A loop without a declaration, a body without braces, a declaration of another name.
        for text in ["for (s = 0; s < 2; ++s) { float s = 1.0; }", "for (int s = 0; s < 2; ++s) a += s;",
                     "for (int s = 0; s < 2; ++s) { float t = 1.0; float s2 = t; }"] {
            XCTAssertEqual(HLSLFrontEnd.loopBodyScopes(text), text)
        }
    }

    /// The prelude's end is the marker's tokens however the preprocessor spaced them, as a UTF-16
    /// offset; a marker in a comment doesn't count, and without one the whole text is the shader's.
    func testEndOfPreludeIsTheMarkersTokens() {
        let prelude = "// é\n/* void weEndOfPrelude() {} */\nvoid  weEndOfPrelude ( )\n{\n}"
        let text = prelude + "\nvoid main() {}"
        XCTAssertEqual(HLSLFrontEnd.endOfPrelude(utf16In: text), prelude.utf16.count)
        XCTAssertEqual(HLSLFrontEnd.endOfPrelude(GLSLTokenizer.tokens(Array(text.utf16))), prelude.utf16.count)
        XCTAssertEqual(HLSLFrontEnd.endOfPrelude(utf16In: "void void weEndOfPrelude() {}"), 29)
        XCTAssertEqual(HLSLFrontEnd.endOfPrelude(utf16In: "void main() { weEndOfPrelude(); }"), 0)
        XCTAssertEqual(HLSLFrontEnd.endOfPrelude(utf16In: ShaderPrelude.endMarker), ShaderPrelude.endMarker.utf16.count)
    }

    /// A loop in the prelude isn't the shader's: only loops after the marker are scoped.
    func testLoopsInThePreludeAreNotScoped() {
        let prelude = "void h() { for (int s = 0; s < 2; ++s) { float s = 1.0; } }\n" + ShaderPrelude.endMarker + "\n"
        let out = convert(prelude + "void main() { for (int s = 0; s < 2; ++s) { float s = 1.0; } }")
        XCTAssertTrue(out.hasPrefix(prelude), out)
        XCTAssertTrue(out.contains("float s_weBody = 1.0;"), out)
    }

    /// HLSL declares system values as inputs (`in uint gl_InstanceID;`, `varying uint
    /// gl_ViewportIndex;`); GLSL has them built in, so file-scope declarations are dropped. A
    /// shader that still names `gl_ViewportIndex` takes the layer extension after `#version`.
    func testSystemValueDeclarationsAreDropped() {
        let text = "#version 450\n#define X 1\nin uint gl_InstanceID;\nout\n  uint gl_ViewportIndex ;\nin int gl_VertexID; in vec2 a;\nvoid main() { gl_ViewportIndex = gl_InstanceID; }\n"
        XCTAssertEqual(ShaderPrelude.builtInDeclarations(text),
                       "#version 450\n#extension GL_ARB_shader_viewport_layer_array : require\n#define X 1\n\n\n in vec2 a;\nvoid main() { gl_ViewportIndex = gl_InstanceID; }\n")
        // Declaring the viewport index without naming it again takes no extension.
        XCTAssertEqual(ShaderPrelude.builtInDeclarations("#version 450\nout uint gl_ViewportIndex;\nvoid main() {}\n"),
                       "#version 450\n\nvoid main() {}\n")
        // Only file-scope declarations of these names, each its own statement.
        for kept in ["#version 450\nvoid main() { in uint gl_InstanceID; }\n", "layout(location = 0) in uint gl_InstanceID;\n",
                     "in uint gl_InstanceIDs;\n", "in float gl_InstanceID;\n", "uniform uint gl_VertexID;\n"] {
            XCTAssertEqual(ShaderPrelude.builtInDeclarations(kept), kept)
        }
    }

    /// The prelude is read for signatures but never rewritten.
    func testThePreludeIsNotRewritten() {
        let prelude = "float h(int x) { float y = x; return y; }\n" + ShaderPrelude.endMarker + "\n"
        let out = convert(prelude + "void main() { vec2 a = 0.0; float b = h(2.5); }")
        XCTAssertTrue(out.hasPrefix(prelude), out)
        XCTAssertTrue(out.contains("vec2 a = vec2(0.0);"), out)
        XCTAssertTrue(out.contains("h(int(2.5))"), out)
    }

    /// HLSL passes a pixel shader's inputs as parameters it may assign to (Workshop effects flip
    /// `v_TexCoord.y` in place); the input is read into a global of its name.
    func testAPixelShaderMayAssignToItsInputs() {
        let vertex = "#version 450\nout vec2 v_TexCoord;\nvoid main() { v_TexCoord = vec2(0.0); }\n"
        let fragment = "#version 450\nin vec2 v_TexCoord;\nout vec4 out_FragColor;\nvoid main() {\n v_TexCoord.y = 1.0 - v_TexCoord.y;\n out_FragColor = vec4(v_TexCoord, 0.0, 1.0);\n}\n"
        let pair = HLSLLinkage.link(vertex: vertex, fragment: fragment)
        XCTAssertTrue(pair.fragment.contains("in vec2 v_TexCoord_weVarying;\nvec2 v_TexCoord;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("v_TexCoord = v_TexCoord_weVarying;"), pair.fragment)
    }
}
