import Foundation
import CoreFoundation
import CryptoKit

/// A strict, static 2D image subset. Every unsupported dependency/behavior blocks
/// isRenderableSubset; inspection never executes shaders, expressions or SceneScript.
struct SceneWallpaperInspector {
    static func inspect(projectURL: URL, propertiesJSON: Data? = nil, limits: SceneReadLimits = SceneReadLimits(), engineAssets:SceneEngineAssetBundle? = nil) throws -> SceneWallpaperInspection {
        guard projectURL.isFileURL, projectURL.lastPathComponent == "project.json" else { throw SceneWallpaperFailure(message: "Scene inspection requires a local project.json.") }
        let source = try SceneAssetSource(rootURL: projectURL.deletingLastPathComponent(), limits: limits,engineAssets:engineAssets)
        let project = try object(source.read("project.json", maximumBytes: limits.maximumJSONBytes, looseOnly: true))
        guard (project["type"] as? String)?.lowercased() == "scene", let file = project["file"] as? String else { throw SceneWallpaperFailure(message: "Project is not a Scene wallpaper with an entry.") }
        _ = try ScenePackageArchive.normalizedPath(file)
        let scenePath: String
        if file.lowercased().hasSuffix(".pkg") { try source.useArchive(file); scenePath = "scene.json" }
        else if source.containsLoose(file) { scenePath = file }
        else { try source.useArchive("scene.pkg"); scenePath = file }
        let scene = try object(source.read(scenePath, maximumBytes: limits.maximumJSONBytes))
        let definitions = ((project["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
        var values = definitions.compactMapValues { $0["value"] }
        if let propertiesJSON {
            guard propertiesJSON.count <= limits.maximumJSONBytes else { throw SceneWallpaperFailure(message: "Scene property payload exceeds JSON limit.") }
            for (key, value) in try object(propertiesJSON) {
                guard definitions[key] != nil else { throw SceneWallpaperFailure(message: "Unknown Scene user property: \(key)") }
                values[key] = (value as? [String: Any])?["value"] ?? value
            }
        }
        var diagnostics: [SceneDiagnostic] = []
        func unsupported(_ path: String, _ message: String) { diagnostics.append(SceneDiagnostic(severity: .unsupported, path: path, message: message)) }
        var allowedScriptWrappers: Set<String> = []
        var scriptBindings: [SceneScriptBindingSpec] = []
        var scriptSourceBytes = 0
        for key in scene.keys where !["version", "camera", "general", "objects"].contains(key) { unsupported("scene." + key, "Unrecognized scene-level behavior.") }
        guard let general = scene["general"] as? [String: Any], let projection = general["orthogonalprojection"] as? [String: Any] else { throw SceneWallpaperFailure(message: "Only explicit 2D orthographic scenes are supported.") }
        let width = try number(projection["width"]), height = try number(projection["height"])
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw SceneWallpaperFailure(message: "Unsafe Scene canvas size.") }
        let canvas = SceneVector2(x: width, y: height)
        var fidelityNotes:[String]=[]
        let parallaxExplicitlyDisabled = general["cameraparallax"].map { (try? boolean($0)) == false } ?? false
        let generalKeys: Set<String> = ["orthogonalprojection","clearcolor","clearenabled","ambientcolor","skylightcolor","bloom","bloomstrength","bloomthreshold","bloomhdrfeather","bloomhdriterations","bloomhdrscatter","bloomhdrstrength","bloomhdrthreshold","bloomtint","hdr","camerafade","cameraparallax","cameraparallaxamount","cameraparallaxdelay","cameraparallaxmouseinfluence","camerapreview","camerashake","camerashakeamplitude","camerashakeroughness","camerashakespeed","farz","nearz","fov","zoom","windenabled","winddirection","windstrength","gravitydirection","gravitystrength","lightconfig","perspectiveoverridefov"]
        for key in general.keys where !generalKeys.contains(key) { unsupported("general." + key,"Unrecognized scene-global behavior.") }
        let zoom = try number(general["zoom"] ?? 1)
        if !zoom.isFinite || zoom <= 0 || zoom > 1_000 { unsupported("general.zoom","Orthographic camera zoom must be finite and in (0, 1000].") }
        for key in projection.keys where !["width","height"].contains(key) { unsupported("general.orthogonalprojection." + key,"Unsupported projection setting.") }

        let clear = try vector(general["clearcolor"] ?? "0 0 0")
        guard [clear.x,clear.y,clear.z].allSatisfy({(0...1).contains($0)}) else { throw SceneWallpaperFailure(message:"Invalid Scene clear color.") }
        // Wind only affects particle/deformation operators, none of which are
        // accepted as image passes. Its environment setting is inert for this
        // subset; particle nodes themselves still block the complete scene.
        for key in ["hdr", "camerashake"] {
            if let value = general[key], (value as? Bool) != false { unsupported("general." + key, "Dynamic/lighting/camera behavior is unsupported.") }
        }
        var parallax:SceneParallax?
        if try boolean(general["cameraparallax"] ?? false) {
            let amount=try number(general["cameraparallaxamount"] ?? 0.1),delay=try number(general["cameraparallaxdelay"] ?? 0.1),influence=try number(general["cameraparallaxmouseinfluence"] ?? 1)
            guard (0...2).contains(amount),(0...10).contains(delay),(0...2).contains(influence) else {throw SceneWallpaperFailure(message:"Unsafe 2D camera parallax settings.")}
            parallax = .init(amount:amount,delay:delay,mouseInfluence:influence)
            fidelityNotes.append("Camera parallax applies bounded per-layer cursor displacement and exponential delay; exact Windows smoothing/sign conventions are unverified.")
        }
        var bloom:SceneBloom?
        if try boolean(general["bloom"] ?? false) {
            let strength=try number(general["bloomstrength"] ?? 0.6),threshold=try number(general["bloomthreshold"] ?? 1),tint=try vector(general["bloomtint"] ?? "1 1 1")
            guard (0...10).contains(strength),(0...100).contains(threshold),[tint.x,tint.y,tint.z].allSatisfy({(0...1).contains($0)}) else {throw SceneWallpaperFailure(message:"Invalid LDR bloom parameters.")}
            bloom = .init(strength:strength,threshold:threshold,tint:tint)
            fidelityNotes.append("Bloom uses a local linear-float threshold/blur pyramid; Windows filter/color-space parity is unverified.")
        }
        let cameraFade = try boolean(general["camerafade"] ?? false)
        if (general["clearenabled"] as? Bool) == false { unsupported("general.clearenabled", "Persistent framebuffer composition is unsupported.") }
        var center = SceneVector3(x:0,y:0,z:-1), eye = SceneVector3(x:0,y:0,z:0), up = SceneVector3(x:0,y:1,z:0)
        if scene["camera"] != nil && !(scene["camera"] is [String:Any]) { unsupported("camera","Invalid camera representation.") }
        if let camera = scene["camera"] as? [String: Any] {
            center = try vector(camera["center"] ?? "0 0 -1"); eye = try vector(camera["eye"] ?? "0 0 0"); up = try vector(camera["up"] ?? "0 1 0")
            let values=[center.x,center.y,center.z,eye.x,eye.y,eye.z,up.x,up.y,up.z]
            let upLength=hypot(up.x,up.y)
            if !values.allSatisfy({$0.isFinite && abs($0)<=1_000_000}) || center.x != eye.x || center.y != eye.y || center.z >= eye.z || up.z != 0 || !upLength.isFinite || upLength < 1e-9 {
                unsupported("camera", "Only a finite 2D orthographic camera looking down -Z with XY translation and roll is supported.")
            }
        }
        let nearZ = try number(general["nearz"] ?? 0.01), farZ = try number(general["farz"] ?? 10_000)
        if !nearZ.isFinite || nearZ <= 0 { unsupported("general.nearz","Near Z must be a finite positive 3D clipping distance.") }
        if !farZ.isFinite || farZ <= nearZ { unsupported("general.farz","Far Z must be finite and greater than near Z.") }
        // Real local packages encode the 2D camera around (0,0,0)->(0,0,-1),
        // while the established accepted fixture uses canvas center at Z=1000
        // looking at Z=0. Preserve the matching origin for both encodings.
        let projectionOrigin = center.z == 0 && eye.z > 0 ? SceneVector2(x:width/2,y:height/2) : SceneVector2(x:0,y:0)
        let sceneCamera=SceneCamera2D(center:center,eye:eye,up:up,zoom:zoom,nearZ:nearZ,farZ:farZ,cameraFade:cameraFade,projectionOrigin:projectionOrigin)
        guard let objects = scene["objects"] as? [[String: Any]], objects.count <= limits.maximumLayers else { throw SceneWallpaperFailure(message: "Invalid/oversized Scene object list.") }
        var layers: [SceneImageLayer] = [], textures: [String: SceneTextureAsset] = [:], usedIDs: Set<Int> = [], textureBytes = 0, texturePixels = 0
        func loadTexture(_ path:String)throws {
            if textures[path] != nil {return}
            let remaining=limits.maximumTextureBytes-textureBytes
            guard remaining>0 else {throw SceneWallpaperFailure(message:"Scene texture byte budget exceeded.")}
            let data=try source.read(path,maximumBytes:min(remaining,limits.maximumEntryBytes))
            let texture=try SceneTextureReader.read(data,path:path,limits:limits,maximumDecodedBytes:remaining)
            guard texture.storageWidth*texture.storageHeight<=limits.maximumTotalTexturePixels-texturePixels else {throw SceneWallpaperFailure(message:"Scene texture pixel budget exceeded.")}
            textureBytes+=texture.data.count;texturePixels+=texture.storageWidth*texture.storageHeight;textures[path]=texture
        }
        if objects.isEmpty { unsupported("objects", "No supported image layers are present.") }
        for (index, layer) in objects.enumerated() {
            let path = "objects[\(index)]"
            do {
                let identifier = try number(layer["id"])
                guard identifier >= 0, identifier <= Double(Int32.max), identifier.rounded() == identifier else { throw SceneWallpaperFailure(message: "Invalid Scene layer id.") }
                let id = Int(identifier)
                guard usedIDs.insert(id).inserted else { throw SceneWallpaperFailure(message: "Scene layer IDs must be unique.") }
                let parentID: Int?
                if let rawParent = layer["parent"] {
                    let parent = try number(rawParent)
                    guard parent >= 0, parent <= Double(Int32.max), parent.rounded() == parent else { throw SceneWallpaperFailure(message: "Scene parent must be a nonnegative integer layer ID.") }
                    parentID = Int(parent)
                } else { parentID = nil }
                var bindings: [ScenePropertyBinding] = []
                var layerScripts: [SceneScriptBindingSpec] = []
                func bound(_ key: String, _ fallback: Any) throws -> Any {
                    guard let raw = layer[key] else { return fallback }
                    guard let wrapper = raw as? [String: Any] else { return raw }
                    let hasScript = wrapper["script"] != nil
                    let allowedKeys: Set<String> = hasScript ? ["user","value","script","scriptproperties"] : ["user","value"]
                    guard Set(wrapper.keys).isSubset(of: allowedKeys), let value = wrapper["value"] else {
                        throw SceneWallpaperFailure(message: "Unsupported expression/script property wrapper: \(key)")
                    }
                    var resolved = value
                    if let user = wrapper["user"] {
                        guard let user = user as? String, definitions[user] != nil, let selected = values[user] else {
                            throw SceneWallpaperFailure(message: "Unsupported/missing direct user-property binding: \(key)")
                        }
                        bindings.append(ScenePropertyBinding(target: key, propertyKey: user)); resolved = selected
                    }
                    if hasScript {
                        guard let code = wrapper["script"] as? String else { throw SceneWallpaperFailure(message: "SceneScript source must be inline text.") }
                        try SceneScriptSourcePolicy.validateInline(code)
                        guard scriptBindings.count + layerScripts.count < SceneScriptSourcePolicy.maximumBindings,
                              scriptSourceBytes + code.utf8.count <= SceneScriptSourcePolicy.maximumTotalSourceBytes else {
                            throw SceneWallpaperFailure(message: "SceneScript exceeds 64 bindings or 1 MiB aggregate source.")
                        }
                        var properties: [String: GWJSONValue] = [:]
                        var propertyBindings: [String: String] = [:]
                        if let rawProperties = wrapper["scriptproperties"] {
                            guard let entries = rawProperties as? [String: Any], entries.count <= 128 else {
                                throw SceneWallpaperFailure(message: "Invalid or oversized SceneScript property map.")
                            }
                            for (name, raw) in entries {
                                guard !name.isEmpty, name.utf8.count <= 256, !name.contains("\0") else {
                                    throw SceneWallpaperFailure(message: "Invalid SceneScript property name.")
                                }
                                var selected = raw
                                if let property = raw as? [String: Any] {
                                    guard Set(property.keys).isSubset(of: ["user","value"]), let initial = property["value"] else {
                                        throw SceneWallpaperFailure(message: "Unsupported SceneScript property wrapper: \(name)")
                                    }
                                    selected = initial
                                    if let user = property["user"] {
                                        guard let user = user as? String, definitions[user] != nil, let current = values[user] else {
                                            throw SceneWallpaperFailure(message: "Unsupported/missing SceneScript property user binding: \(name)")
                                        }
                                        selected = current
                                        propertyBindings[name] = user
                                    }
                                }
                                properties[name] = try jsonValue(selected)
                            }
                            guard try JSONEncoder().encode(properties).count <= 65_536 else {
                                throw SceneWallpaperFailure(message: "SceneScript property map exceeds 64 KiB.")
                            }
                        }
                        layerScripts.append(SceneScriptBindingSpec(id: "\(id).\(key)", layerID: id, target: key,
                            source: code, initialValue: try jsonValue(resolved), scriptProperties: properties, scriptPropertyBindings: propertyBindings))
                        scriptSourceBytes += code.utf8.count
                        allowedScriptWrappers.insert("scene.objects[\(index)].\(key)")
                    }
                    return resolved
                }
                // A particle/shape is a drawable, never an empty transform group.
                // Report its concrete dependency instead of a collection of unknown keys.
                if layer["text"] != nil {
                    let allowed:Set<String>=["id","parent","name","text","font","pointsize","origin","angles","scale","size","color","alpha","visible","padding","spacing","horizontalalign","verticalalign","limitrows","limitwidth","limituseellipsis","maxrows","maxwidth","disablepropagation"]
                    guard Set(layer.keys).isSubset(of:allowed),let fontPath=layer["font"] as? String else {throw SceneWallpaperFailure(message:"Unsupported text layer fields or missing font dependency.")}
                    if let propagation=layer["disablepropagation"],try boolean(propagation) {throw SceneWallpaperFailure(message:"Text propagation overrides are unsupported.")}
                    for key in ["limitrows","limitwidth","limituseellipsis"] {if try boolean(layer[key] ?? false) {throw SceneWallpaperFailure(message:"Wrapped/limited text layout is unsupported.")}}
                    if let spacing=layer["spacing"],try vector(spacing) != .init(x:0,y:0,z:0) {throw SceneWallpaperFailure(message:"Nonzero text spacing is unsupported.")}
                    guard let value=try bound("text","") as? String else {throw SceneWallpaperFailure(message:"Text binding must be a string.")}
                    let rawOrigin=try vector(bound("origin","0 0 0")),angles=try vector(bound("angles","0 0 0")),rawScale=try vector(bound("scale","1 1 1")),size=try vector(bound("size","256 128")),tint=try vector(bound("color","1 1 1")),alpha=try number(bound("alpha",1)),padding=try vector(layer["padding"] ?? "0 0")
                    guard rawOrigin.z==0,angles.x==0,angles.y==0,padding.z==0,(0...1).contains(alpha),[tint.x,tint.y,tint.z].allSatisfy({(0...1).contains($0)}) else {throw SceneWallpaperFailure(message:"Unsupported 3D or color state for text.")}
                    let fontData:Data
                    do {fontData=try source.read(fontPath,maximumBytes:2*1024*1024)}
                    catch {diagnostics.append(.init(severity:.missing,path:fontPath,message:"文字字体不可用："+error.localizedDescription));continue}
                    let text=SceneTextLayer(value:value,fontData:fontData,pointSize:try number(layer["pointsize"] ?? 32),padding:.init(x:padding.x,y:padding.y),horizontalAlignment:layer["horizontalalign"] as? String ?? "center",verticalAlignment:layer["verticalalign"] as? String ?? "center")
                    try SceneTextRenderer.validate(text,size:.init(x:size.x,y:size.y))
                    layers.append(.init(id:id,name:layer["name"] as? String ?? "Text \(id)",modelPath:"",materialPath:"",texturePath:"__gw_text_\(id)",origin:rawOrigin,anglesDegrees:angles,scale:.init(x:rawScale.x,y:rawScale.y,z:1),size:.init(x:size.x,y:size.y),tint:tint,opacity:alpha,isVisible:try boolean(bound("visible",true)),bindings:bindings,parentID:parentID,textLayer:text))
                    scriptBindings += layerScripts
                    continue
                }
                if let particle = layer["particle"] as? String {
                    do {
                        let definition = try object(source.read(particle, maximumBytes: limits.maximumJSONBytes))
                        var spec:SceneSpriteParticleSystem?
                        do { spec = try spriteParticles(definition, overrides:layer["instanceoverride"] as? [String:Any] ?? [:]) }
                        catch { unsupported(path + ".particle", "粒子系统（\(layer["name"] as? String ?? String(id))）：" + error.localizedDescription) }
                        guard let materialName=definition["material"] as? String else {throw SceneWallpaperFailure(message:"Particle material dependency is missing.")}
                        let material=try object(source.read(materialName,maximumBytes:limits.maximumJSONBytes))
                        guard Set(material.keys)==["passes"], let passes=material["passes"] as? [[String:Any]],passes.count==1 else {throw SceneWallpaperFailure(message:"Particle requires one material pass.")}
                        let pass=passes[0]
                        let accepted:Set<String>=["shader","textures","blending","combos","constantshadervalues","cullmode","depthtest","depthwrite","alphawriting"]
                        guard Set(pass.keys).isSubset(of:accepted),pass["shader"] as? String == "genericparticle",
                              let blend=(pass["blending"] as? String).flatMap(SceneImageBlend.init(rawValue:)),
                              let refs=pass["textures"] as? [String], !refs.isEmpty else {throw SceneWallpaperFailure(message:"Unsupported particle material shader/state.")}
                        var materialSupported=refs.count==1
                        var refractionAmount:Double=0
                        let combos=pass["combos"] as? [String:Any] ?? [:],constants=pass["constantshadervalues"] as? [String:Any] ?? [:]
                        if refs.count==2,Set(combos.keys).isSubset(of:["CUTOUT","REFRACT"]),(try? number(combos["REFRACT"]))==1,(try? number(combos["CUTOUT"] ?? 0))==0 {
                            let keys:Set<String>=["ui_editor_properties_cutout_start","ui_editor_properties_cutout_end","ui_editor_properties_cutout_opacity","ui_editor_properties_overbright","ui_editor_properties_refract_amount"]
                            materialSupported=Set(constants.keys).isSubset(of:keys) && (try? number(constants["ui_editor_properties_overbright"] ?? 1))==1
                            refractionAmount=try number(constants["ui_editor_properties_refract_amount"] ?? 0.05)
                            materialSupported=materialSupported && (0...1).contains(refractionAmount)
                            fidelityNotes.append("Water refraction uses real normal maps and preceding-layer framebuffer; exact Windows shading response is unverified.")
                        } else if !combos.isEmpty || !constants.isEmpty {materialSupported=false}

                        for (key,value) in [("cullmode","nocull"),("depthtest","disabled"),("depthwrite","disabled"),("alphawriting","default")] where pass[key] != nil {
                            if pass[key] as? String != value {materialSupported=false}
                        }
                        if !materialSupported {unsupported(materialName,"粒子材质的折射、多纹理或自定义 shader 状态尚未支持。")}
                        var texturePath:String?
                        for reference in refs {
                            let dependency=try ScenePackageArchive.normalizedPath("materials/"+reference+".tex")
                            if texturePath==nil {texturePath=dependency}
                            do {
                                if textures[dependency]==nil {
                                    let remaining=limits.maximumTextureBytes-textureBytes
                                    guard remaining>0 else {throw SceneWallpaperFailure(message:"Particle texture budget exceeded.")}
                                    let data=try source.read(dependency,maximumBytes:min(remaining,limits.maximumEntryBytes))
                                    let texture=try SceneTextureReader.read(data,path:dependency,limits:limits,maximumDecodedBytes:remaining)
                                    guard texture.storageWidth*texture.storageHeight<=limits.maximumTotalTexturePixels-texturePixels else {throw SceneWallpaperFailure(message:"Particle texture pixel budget exceeded.")}
                                    textureBytes+=texture.data.count;texturePixels+=texture.storageWidth*texture.storageHeight;textures[dependency]=texture
                                }
                            } catch {diagnostics.append(.init(severity:.missing,path:dependency,message:"粒子纹理不可用："+error.localizedDescription))}
                        }
                        if var spec,materialSupported,let texturePath,textures[texturePath] != nil {
                            if textures[texturePath]?.animation != nil,spec.renderer == .rope {throw SceneWallpaperFailure(message:"Animated atlas ropes are unsupported.")}
                            if refs.count==2,textures["materials/"+refs[1]+".tex"]?.animation != nil {throw SceneWallpaperFailure(message:"Animated normal maps are unsupported.")}
                            for child in definition["children"] as? [[String:Any]] ?? [] {
                                guard let childPath=child["name"] as? String else {throw SceneWallpaperFailure(message:"Missing particle child path.")}
                                let childDefinition=try object(source.read(childPath,maximumBytes:limits.maximumJSONBytes))
                                guard (childDefinition["children"] is NSNull) || (childDefinition["children"] as? [Any])?.isEmpty==true || childDefinition["children"]==nil else {throw SceneWallpaperFailure(message:"Nested static particle children exceed target subset.")}
                                let childSpec=try spriteParticles(childDefinition,overrides:layer["instanceoverride"] as? [String:Any] ?? [:])
                                guard let childMaterialPath=childDefinition["material"] as? String else {throw SceneWallpaperFailure(message:"Missing child material.")}
                                let childMaterial=try object(source.read(childMaterialPath,maximumBytes:limits.maximumJSONBytes))
                                guard let childPasses=childMaterial["passes"] as? [[String:Any]],childPasses.count==1,let childPass=childPasses.first,childPass["shader"] as? String=="genericparticle",let childBlend=(childPass["blending"] as? String).flatMap(SceneImageBlend.init(rawValue:)),let childRefs=childPass["textures"] as? [String],childRefs.count==1,(childPass["combos"] as? [String:Any] ?? [:]).isEmpty,(childPass["constantshadervalues"] as? [String:Any] ?? [:]).isEmpty else {throw SceneWallpaperFailure(message:"Unsupported static child material state.")}
                                let childTexture=try ScenePackageArchive.normalizedPath("materials/"+childRefs[0]+".tex")
                                try loadTexture(childTexture)
                                if textures[childTexture]?.animation != nil,childSpec.renderer == .rope {throw SceneWallpaperFailure(message:"Animated child atlas ropes are unsupported.")}
                                spec.children.append(.init(system:childSpec,texturePath:childTexture,normalTexturePath:nil,blend:childBlend))
                            }
                            let acceptedLayer:Set<String>=["id","parent","name","particle","instanceoverride","image","model","solid","origin","angles","scale","visible","disablepropagation"]
                            guard Set(layer.keys).isSubset(of:acceptedLayer),layer["image"] == nil || layer["image"] is NSNull,layer["model"] == nil || layer["model"] is NSNull else {throw SceneWallpaperFailure(message:"Unsupported particle layer behavior.")}
                            if let disabled=layer["disablepropagation"],try boolean(disabled) {throw SceneWallpaperFailure(message:"Particle propagation override is unsupported.")}
                            if (try? number(definition["flags"] ?? 0))==1,parentID != nil {throw SceneWallpaperFailure(message:"World-space particles under animated hierarchy parents are unsupported.")}
                            let origin=try vector(layer["origin"] ?? "0 0 0"),angles=try vector(layer["angles"] ?? "0 0 0"),scale=try vector(layer["scale"] ?? "1 1 1")
                            guard origin.z==0,angles.x==0,angles.y==0 else {throw SceneWallpaperFailure(message:"Particle sprite backend requires a 2D transform.")}
                            layers.append(.init(id:id,name:layer["name"] as? String ?? "Particle \(id)",modelPath:particle,materialPath:materialName,texturePath:texturePath,origin:origin,anglesDegrees:angles,scale:.init(x:scale.x,y:scale.y,z:1),size:.init(x:1,y:1),tint:.init(x:1,y:1,z:1),opacity:1,isVisible:try boolean(layer["visible"] ?? true),bindings:[],parentID:parentID,blend:blend,particleSystem:spec,normalTexturePath:refs.count==2 ? "materials/"+refs[1]+".tex" : nil,refractionAmount:refractionAmount))
                        }
                    } catch { diagnostics.append(.init(severity:.unsupported,path:path+".particle",message:error.localizedDescription)) }
                    continue
                }
                if let shape=layer["shape"] as? String {
                    do {
                        guard shape=="quad",Set(layer.keys).isSubset(of:["id","parent","name","shape","origin","angles","scale","effects","disablepropagation","visible"]) else {throw SceneWallpaperFailure(message:"Unsupported procedural shape geometry/state.")}
                        if let flag=layer["disablepropagation"],try boolean(flag) {throw SceneWallpaperFailure(message:"Shape propagation override is unsupported.")}
                        let effectDefinition=try object(source.read("effects/lightshafts/effect.json",maximumBytes:limits.maximumJSONBytes))
                        guard Set(effectDefinition.keys).isSubset(of:["version","replacementkey","name","description","group","preview","passes","dependencies","gizmos"]),effectDefinition["replacementkey"] as? String=="lightshafts",let effectPasses=effectDefinition["passes"] as? [[String:Any]],effectPasses.count==1,effectPasses[0]["material"] as? String=="materials/effects/lightshafts.json" else {throw SceneWallpaperFailure(message:"Changed lightshaft effect pass graph is unsupported.")}
                        let effectMaterial=try object(source.read("materials/effects/lightshafts.json",maximumBytes:limits.maximumJSONBytes))
                        guard let materialPasses=effectMaterial["passes"] as? [[String:Any]],materialPasses.count==1,materialPasses[0]["shader"] as? String=="effects/lightshafts",materialPasses[0]["blending"] as? String=="normal" else {throw SceneWallpaperFailure(message:"Changed lightshaft material is unsupported.")}
                        guard let effects=layer["effects"] as? [[String:Any]],effects.count==1,let effect=effects.first,effect["file"] as? String=="effects/lightshafts/effect.json",Set(effect.keys).isSubset(of:["file","id","name","passes","visible"]),let passes=effect["passes"] as? [[String:Any]],passes.count==1,let pass=passes.first,Set(pass.keys).isSubset(of:["id","combos","constantshadervalues"]) else {throw SceneWallpaperFailure(message:"Only the bounded built-in direct lightshaft shape is supported.")}
                        // The native formula is a port of this exact authored
                        // shader variant. Changed/custom sources cannot be ignored.
                        for (file,hash) in [("shaders/effects/lightshafts.vert","fc65a0011fcae963679c3411c017da95c3c5ddcc9808b0777196f0334547e471"),("shaders/effects/lightshafts.frag","3e03ff559af5a8eb7951d1be590c48976a78f2e159bcc6778a9e48923d48d940")] {
                            let data=try source.read(file,maximumBytes:limits.maximumJSONBytes)
                            guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==hash else {throw SceneWallpaperFailure(message:"Custom/changed lightshaft shader is unsupported: \(file)")}
                        }
                        let shaft=try lightShaft(pass)
                        var missingTexture=false
                        for texturePath in [shaft.noiseTexturePath] + (shaft.rendering==1 ? [shaft.gradientTexturePath]:[]) {
                            do {try loadTexture(texturePath)}
                            catch is CancellationError {throw CancellationError()}
                            catch {diagnostics.append(.init(severity:.missing,path:texturePath,message:"光束纹理不可用："+error.localizedDescription));missingTexture=true}
                        }
                        if missingTexture {continue}
                        let origin=try vector(layer["origin"] ?? "0 0 0"),angles=try vector(layer["angles"] ?? "0 0 0"),scale=try vector(layer["scale"] ?? "1 1 1")
                        guard origin.z==0,angles.x==0,angles.y==0 else {throw SceneWallpaperFailure(message:"Only flat procedural lightshaft geometry is supported.")}
                        let visible=try boolean(layer["visible"] ?? true) && boolean(effect["visible"] ?? true)
                        layers.append(.init(id:id,name:layer["name"] as? String ?? "Lightshaft \(id)",modelPath:"",materialPath:"materials/effects/lightshafts.json",texturePath:shaft.noiseTexturePath,origin:origin,anglesDegrees:angles,scale:.init(x:scale.x,y:scale.y,z:1),size:canvas,tint:.init(x:1,y:1,z:1),opacity:1,isVisible:visible,bindings:[],parentID:parentID,blend:.additive,lightShaft:shaft))
                        fidelityNotes.append("Lightshafts use the packaged shader's fixed native formula; engine blend/filter/color-space parity is unverified.")
                    } catch {diagnostics.append(.init(severity:.unsupported,path:path+".effects",message:error.localizedDescription))}
                    continue
                }
                if let disabled = layer["disablepropagation"], try boolean(disabled) {
                    unsupported(path + ".disablepropagation", "Disabling effect propagation is not supported.")
                }
                let image = layer["image"] as? String
                let isTransformOnly = image == nil
                let allowed: Set<String> = ["id","name","image","origin","angles","scale","size","visible","color","alpha","effects","alignment","pivot","perspective","parent","parallaxDepth","brightness","colorBlendMode","locktransforms","ledsource","solid","disablepropagation"]
                let common: Set<String> = ["id","parent","name","origin","angles","scale","visible","parallaxDepth","effects","locktransforms","disablepropagation"]
                for key in layer.keys where !(isTransformOnly ? common : allowed).contains(key) {
                    unsupported(path + "." + key, isTransformOnly ? "Unsupported transform-only node field or drawable type." : "Unrecognized image-layer behavior.")
                }
                if isTransformOnly {
                    if let name = layer["name"], !(name is String) { throw SceneWallpaperFailure(message: "Transform-only node name must be text.") }
                    if let locked = layer["locktransforms"] { _ = try boolean(locked) }
                }
                var colorKey:SceneColorKey?
                if let rawEffects=layer["effects"] {
                    if let effects=rawEffects as? [[String:Any]],effects.isEmpty {} else {
                        do {colorKey=try parseColorKey(rawEffects,source:source,limits:limits)}
                        catch {unsupported(path+".effects",error.localizedDescription)}
                    }
                }
                if (layer["perspective"] as? Bool) == true || (layer["alignment"] as? String).map({ $0 != "center" }) == true { unsupported(path, "Perspective/non-centered geometry is unsupported.") }
                if let pivot = layer["pivot"], try vector(pivot) != SceneVector3(x: 0,y: 0,z: 0) { unsupported(path + ".pivot", "Nonzero pivot is unsupported.") }
                for (key, normal) in [("brightness",1.0),("colorBlendMode",0.0)] { if let value = layer[key], (try? number(value)) != normal { unsupported(path + "." + key, "Non-default color behavior is unsupported.") } }
                var parallaxDepth=SceneVector2(x:0,y:0)
                if let depth=layer["parallaxDepth"] {
                    let value=try vector(depth)
                    guard value.z==0,[value.x,value.y].allSatisfy({abs($0)<=10}) else {throw SceneWallpaperFailure(message:"Only bounded XY parallax depth is supported.")}
                    if parallax != nil {parallaxDepth = .init(x:value.x,y:value.y)}
                    else if !parallaxExplicitlyDisabled && (value.x != 0 || value.y != 0) {unsupported(path+".parallaxDepth","Parallax depth requires explicit camera settings.")}
                }
                let origin = try vector(bound("origin", "0 0 0")), angles = try vector(bound("angles", "0 0 0")), rawScale = try vector(bound("scale", "1 1 1"))
                let scale=SceneVector3(x:rawScale.x,y:rawScale.y,z:isTransformOnly ? rawScale.z:1)
                if origin.z != 0 || angles.x != 0 || angles.y != 0 || scale.z != 1 { unsupported(path, "Only zero-depth 2D Z rotation and XY scale are supported.") }
                let visible = try boolean(bound("visible", true))
                if isTransformOnly {
                    layers.append(SceneImageLayer(id: id,name: layer["name"] as? String ?? "Layer \(id)",
                        modelPath: "",materialPath: "",texturePath: "",origin: origin,anglesDegrees: angles,scale: scale,
                        size: SceneVector2(x: 1,y: 1),tint: SceneVector3(x: 1,y: 1,z: 1),opacity: 1,isVisible: visible,
                        bindings: bindings,parentID: parentID,isTransformOnly: true))
                    scriptBindings += layerScripts
                    continue
                }
                let tint = try vector(bound("color", "1 1 1")), alpha = try number(bound("alpha", 1))
                guard (0...1).contains(alpha), [tint.x,tint.y,tint.z].allSatisfy({ (0...1).contains($0) }) else { throw SceneWallpaperFailure(message: "Invalid image tint/opacity.") }
                let modelPath = try ScenePackageArchive.normalizedPath(image!)
                let model = try object(source.read(modelPath, maximumBytes: limits.maximumJSONBytes))
                for key in model.keys where !["material","autosize","width","height","nopadding"].contains(key) { unsupported(modelPath + "." + key, "Unsupported image model feature.") }
                guard let materialName = model["material"] as? String else { throw SceneWallpaperFailure(message: "Image model is missing its material dependency.") }
                let materialPath = try ScenePackageArchive.normalizedPath(materialName), material = try object(source.read(materialPath, maximumBytes: limits.maximumJSONBytes))
                for key in material.keys where key != "passes" { unsupported(materialPath + "." + key, "Unsupported material feature.") }
                guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
                      let shader = passes[0]["shader"] as? String, ["genericimage", "genericimage2", "genericimage4"].contains(shader),
                      let textureNames = passes[0]["textures"] as? [String], textureNames.count == 1 else { throw SceneWallpaperFailure(message: "Only a single generic image material pass/texture is supported.") }
                let pass = passes[0]
                let passKeys: Set<String> = ["shader","textures","blending","combos","constantshadervalues","cullmode","depthtest","depthwrite"]
                for key in pass.keys where !passKeys.contains(key) { unsupported(materialPath + ".passes." + key, "Custom material state is unsupported.") }
                for key in ["combos","constantshadervalues"] {
                    if let value = pass[key], (value as? [String:Any])?.isEmpty != true {
                        unsupported(materialPath + ".passes." + key, "Nonempty shader constants/combos are unsupported.")
                    }
                }
                for (key, expected) in [("cullmode","nocull"),("depthtest","disabled"),("depthwrite","disabled")] {
                    if let value = pass[key], (value as? String) != expected {
                        unsupported(materialPath + ".passes." + key, "Non-default cull/depth state is unsupported.")
                    }
                }
                let blend = (pass["blending"] as? String).flatMap(SceneImageBlend.init(rawValue:))
                if blend == nil { unsupported(materialPath + ".blending", "Only translucent and additive image blending are supported.") }
                let reference = textureNames[0]
                guard !reference.hasPrefix("_rt_") else { throw SceneWallpaperFailure(message: "Runtime framebuffer textures are unsupported.") }
                let texturePath = try ScenePackageArchive.normalizedPath("materials/" + reference + ".tex")
                if textures[texturePath] == nil {
                    let remaining = limits.maximumTextureBytes - textureBytes
                    guard remaining > 0 else { throw SceneWallpaperFailure(message: "Scene texture byte budget exceeded.") }
                    let data = try source.read(texturePath, maximumBytes: min(remaining, limits.maximumEntryBytes))
                    let texture = try SceneTextureReader.read(data, path: texturePath, limits: limits, maximumDecodedBytes: remaining)
                    guard texture.data.count <= remaining, texture.storageWidth * texture.storageHeight <= limits.maximumTotalTexturePixels - texturePixels else { throw SceneWallpaperFailure(message: "Scene total decoded texture pixel budget exceeded.") }
                    textureBytes += texture.data.count; texturePixels += texture.storageWidth * texture.storageHeight; textures[texturePath] = texture
                }
                if textures[texturePath]?.video != nil {unsupported(path+".video","Embedded Scene video-texture playback is not implemented by this native backend; complete playback is refused.")}
                if textures[texturePath]?.animation != nil {unsupported(path+".texture","Animated TEX atlases require a particle sprite renderer.")}
                if model["width"] != nil || model["height"] != nil {
                    guard try number(model["width"])==Double(textures[texturePath]!.imageWidth),try number(model["height"])==Double(textures[texturePath]!.imageHeight),(try? boolean(model["nopadding"] ?? false))==true else {throw SceneWallpaperFailure(message:"Image model dimensions/padding do not match its texture.")}
                } else if let padding=model["nopadding"] {guard try boolean(padding) else {throw SceneWallpaperFailure(message:"Unsupported image model padding metadata.")}}
                guard layer["size"] != nil || (model["autosize"] as? Bool) == true else { throw SceneWallpaperFailure(message: "Layer size missing and model does not enable autosize.") }
                let fallback = "\(textures[texturePath]!.imageWidth) \(textures[texturePath]!.imageHeight)"
                let size = try vector(bound("size", fallback))
                guard size.x > 0, size.y > 0 else { throw SceneWallpaperFailure(message: "Image layer has invalid size.") }
                layers.append(SceneImageLayer(id: id,name: layer["name"] as? String ?? "Layer \(id)",modelPath: modelPath,materialPath: materialPath,texturePath: texturePath,origin: origin,anglesDegrees: angles,scale: scale,size: SceneVector2(x: size.x,y: size.y),tint: tint,opacity: alpha,isVisible: visible,bindings: bindings,parentID: parentID,blend:blend ?? .translucent,colorKey:colorKey,parallaxDepth:parallaxDepth))
                scriptBindings += layerScripts
            } catch { diagnostics.append(SceneDiagnostic(severity: .invalid,path: path,message: error.localizedDescription)) }
        }
        if layers.contains(where:{$0.particleSystem != nil}),let wind=general["windenabled"],try boolean(wind) {
            let direction=try vector(general["winddirection"] ?? "0 0 1")
            if direction.x != 0 || direction.y != 0 {unsupported("general.windenabled","XY global particle wind coupling is unsupported.")}
        }
        if layers.contains(where:{$0.particleSystem != nil}) {fidelityNotes.append("Particle seeds and fixed-step turbulence/control forces are local numerical conventions; Windows PRNG/noise parity is unverified.")}
        if textures.values.contains(where:{$0.animation != nil}) {fidelityNotes.append("Particle atlas sequences use authored cell rectangles, per-particle lifetime and smooth adjacent-frame blending; Windows filtering parity is unverified.")}
        if textures.values.contains(where:{$0.verifiedStorageVariant}) {fidelityNotes.append("The two current engine RG88 beam files are digest-pinned with the reference-named AlphaChannelPriority bit19; changed variants remain unsupported.")}
        if !layers.contains(where: { !$0.isTransformOnly }) { unsupported("objects", "No supported drawable image layers are present.") }
        do { try SceneHierarchy.validate(layers: layers) }
        catch { diagnostics.append(.init(severity: .invalid,path: "objects.parent",message: error.localizedDescription)) }
        try rejectScripts(scene, path: "scene", depth: 0, allowedWrappers: allowedScriptWrappers, report: unsupported)
        var program: SceneScriptProgram?
        if !scriptBindings.isEmpty {
            do {
                let modules = try source.scriptModules(inlineByteCount: scriptSourceBytes)
                let collected = SceneScriptProgram(bindings: scriptBindings, layers: layers.map(SceneScriptLayerState.init(layer:)),
                    directBindings: layers.flatMap { layer in layer.bindings.map { SceneScriptDirectBindingSpec(layerID: layer.id,target: $0.target,propertyKey: $0.propertyKey) } }, modules: modules)
                for layer in collected.layers { try layer.validate() }
                guard try JSONEncoder().encode(collected).count <= 2_097_152 else { throw SceneWallpaperFailure(message: "SceneScript program exceeds 2 MiB.") }
                program = collected
            } catch { diagnostics.append(.init(severity: .invalid,path: "SceneScript",message: error.localizedDescription)) }
        }
        return SceneWallpaperInspection(canvasSize: canvas,clearColor: clear,camera:sceneCamera,layers: layers,textures: textures,diagnostics: diagnostics,
            scriptProgram: diagnostics.isEmpty ? program : nil,bloom:bloom,fidelityNotes:fidelityNotes,parallax:parallax)
    }
    private static func parseColorKey(_ raw:Any,source:SceneAssetSource,limits:SceneReadLimits)throws->SceneColorKey? {
        guard let effects=raw as? [[String:Any]],effects.count==1,let effect=effects.first,
              Set(effect.keys).isSubset(of:["file","id","name","passes","visible"]),effect["file"] as? String=="effects/colorkey/effect.json",
              let passes=effect["passes"] as? [[String:Any]],passes.count==1,let pass=passes.first,
              Set(pass.keys).isSubset(of:["id","constantshadervalues"]),let constants=pass["constantshadervalues"] as? [String:Any],
              Set(constants.keys).isSubset(of:["alpha","color","fuzziness","tolerance"]) else {throw SceneWallpaperFailure(message:"Only one bounded native color-key effect pass is supported.")}
        let definition=try object(source.read("effects/colorkey/effect.json",maximumBytes:limits.maximumJSONBytes))
        guard definition["replacementkey"] as? String=="colorkey",let declared=definition["passes"] as? [[String:Any]],declared.count==1,declared[0]["material"] as? String=="materials/effects/colorkey.json" else {throw SceneWallpaperFailure(message:"Changed color-key effect graph is unsupported.")}
        let material=try object(source.read("materials/effects/colorkey.json",maximumBytes:limits.maximumJSONBytes))
        guard Set(material.keys)==["passes"],let materialPasses=material["passes"] as? [[String:Any]],materialPasses.count==1,
              Set(materialPasses[0].keys)==["shader","blending","depthtest","depthwrite","cullmode"],materialPasses[0]["shader"] as? String=="effects/colorkey",materialPasses[0]["blending"] as? String=="normal",materialPasses[0]["depthtest"] as? String=="disabled",materialPasses[0]["depthwrite"] as? String=="disabled",materialPasses[0]["cullmode"] as? String=="nocull" else {throw SceneWallpaperFailure(message:"Changed color-key material is unsupported.")}
        for (file,hash) in [("shaders/effects/colorkey.vert","0b346bf8e6d1fb2aafee37d80d46ec4821c08d3fc62b11c42b23112a4b8739cb"),("shaders/effects/colorkey.frag","e05cc509f3a286f9ecee63063280b7f8ce22cee7d8b705b74cee0b133ef71bed")] {
            let bytes=try source.read(file,maximumBytes:limits.maximumJSONBytes)
            guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==hash else {throw SceneWallpaperFailure(message:"Changed/custom color-key shader is unsupported.")}
        }
        let color=try vector(constants["color"] ?? "1 1 1"),alpha=try number(constants["alpha"] ?? 0),fuzz=try number(constants["fuzziness"] ?? 0),tolerance=try number(constants["tolerance"] ?? 0.1)
        guard [color.x,color.y,color.z,alpha].allSatisfy({(0...1).contains($0)}),(0...3).contains(fuzz),(0...3).contains(tolerance) else {throw SceneWallpaperFailure(message:"Unsafe color-key constants.")}
        if !(try boolean(effect["visible"] ?? true)) {return nil}
        return .init(color:color,alpha:alpha,fuzziness:fuzz,tolerance:tolerance)
    }
    private static func lightShaft(_ pass:[String:Any])throws->SceneLightShaft {
        let combos=pass["combos"] as? [String:Any] ?? [:],values=pass["constantshadervalues"] as? [String:Any] ?? [:]
        guard Set(combos.keys).isSubset(of:["DIRECTDRAW","RAYMODE","RAYCORNER","RENDERING"]),(try? number(combos["DIRECTDRAW"]))==1 else {throw SceneWallpaperFailure(message:"Only direct-draw lightshafts are supported.")}
        let keys:Set<String>=["colorastart","colorend","colorwexponent","colorwintensity","noiseamount","noisescale","point0","point1","point2","point3","rayfeather","rayradius","rayscale","raysmoothness","rayspeed","rayzstartangle","rayzzendangle"]
        guard Set(values.keys).isSubset(of:keys) else {throw SceneWallpaperFailure(message:"Unknown lightshaft shader constant.")}
        var result=SceneLightShaft()
        let mode=try number(combos["RAYMODE"] ?? 0),corner=try number(combos["RAYCORNER"] ?? 0),rendering=try number(combos["RENDERING"] ?? 0)
        guard [0.0,1,2].contains(mode),[0.0,1,2,3].contains(corner),[0.0,1].contains(rendering) else {throw SceneWallpaperFailure(message:"Unsupported lightshaft combo.")}
        result.mode=Int(mode);result.corner=Int(corner);result.rendering=Int(rendering)
        let defaults=["0.67728 0.01297","0.76007 0.14043","0.46654 1.09592","0.16363 0.44881"]
        result.points=try (0..<4).map{let p=try vector(values["point\($0)"] ?? defaults[$0]);return .init(x:p.x,y:p.y)}
        result.speed=try number(values["rayspeed"] ?? 0.2);result.radius=try number(values["rayradius"] ?? 0.2);result.smoothness=try number(values["raysmoothness"] ?? 0.75);result.noiseScale=try number(values["noisescale"] ?? 1);result.noiseAmount=try number(values["noiseamount"] ?? 0.33);result.intensity=try number(values["colorwintensity"] ?? 1);result.exponent=try number(values["colorwexponent"] ?? 1);result.startAngle=try number(values["rayzstartangle"] ?? 0);result.endAngle=try number(values["rayzzendangle"] ?? 1)
        let scale=try vector(values["rayscale"] ?? "0.5 0.1"),feather=try vector(values["rayfeather"] ?? "0.05 0.2")
        result.scale = .init(x:scale.x,y:scale.y);result.feather = .init(x:feather.x,y:feather.y)
        result.colorStart=try vector(values["colorastart"] ?? "1 1 1");result.colorEnd=try vector(values["colorend"] ?? "0.5 0.8 1")
        guard [result.speed,result.radius,result.smoothness,result.noiseScale,result.noiseAmount,result.intensity,result.exponent,result.startAngle,result.endAngle,scale.x,scale.y,feather.x,feather.y].allSatisfy({$0.isFinite && abs($0)<=100}),result.exponent>0,result.radius>=0,result.radius<1,result.smoothness>=0,result.smoothness<=1 else {throw SceneWallpaperFailure(message:"Unsafe lightshaft parameters.")}
        return result
    }
    /// Explicit operators only. No unknown operator is omitted; ropes, trails,
    /// turbulence, control points, animation and refraction remain fail-closed.
    private static func spriteParticles(_ raw:[String:Any],overrides:[String:Any]) throws -> SceneSpriteParticleSystem {
        func require(_ ok:Bool,_ text:String)throws {if !ok {throw SceneWallpaperFailure(message:text)}}
        let rootKeys:Set<String>=["children","emitter","initializer","operator","renderer","material","maxcount","starttime","flags","controlpoint","animationmode","sequencemultiplier"]
        try require(Set(raw.keys).isSubset(of:rootKeys),"Unrecognized particle definition field.")
        if let children=raw["children"],!(children is NSNull) {guard let children=children as? [[String:Any]],children.count<=8 else {throw SceneWallpaperFailure(message:"Invalid or oversized static particle child list.")}
            for child in children {try require(Set(child.keys).isSubset(of:["id","name"]) && child["name"] is String,"Event/transform child particles are unsupported.")}}
        if let flags=raw["flags"],!(flags is NSNull) {try require([0.0,1.0].contains(try number(flags)),"Unsupported particle system flags.")}
        if let mode=raw["animationmode"],!(mode is NSNull) {try require((try? number(mode))==0,"Only lifetime-driven default particle sequences are supported.")}
        if let sequence=raw["sequencemultiplier"],!(sequence is NSNull) {try require((try? number(sequence)).map{(0...100).contains($0)}==true,"Unsafe particle sequence multiplier.")}

        if let points=raw["controlpoint"] as? [[String:Any]] {
            for point in points {
                try require(Set(point.keys).isSubset(of:["id","flags","offset","angles","parentcontrolpoint"]),"Particle control-point parent/orientation is unsupported.")
                try require((try? number(point["flags"] ?? 0)).map{(0...3).contains($0)}==true && (try? vector(point["offset"] ?? "0 0 0")) == .init(x:0,y:0,z:0),"Unsupported control point flags/nonzero offset.")
                if let angles=point["angles"],!(angles is NSNull) {try require((try? vector(angles)) == .init(x:0,y:0,z:0),"Rotated particle control points are unsupported.")}
                if let parent=point["parentcontrolpoint"] {try require((try? number(parent)).map{(0...7).contains($0)}==true,"Invalid particle control-point parent.")}
            }
        } else if raw["controlpoint"] != nil {throw SceneWallpaperFailure(message:"Invalid particle control point array.")}
        try require(Set(overrides.keys).isSubset(of:["id","count","rate","size","speed","lifetime","alpha"]),"Unknown particle instance override.")
        func multiplier(_ key:String)throws->Double {let n=try number(overrides[key] ?? 1);try require((0...100).contains(n),"Unsafe particle instance multiplier.");return n}
        var result=SceneSpriteParticleSystem()
        if let sequence=raw["sequencemultiplier"],!(sequence is NSNull) {result.sequenceMultiplier=try number(sequence)}
        result.controlPointFollowsMouse=(raw["controlpoint"] as? [[String:Any]] ?? []).contains{((try? number($0["flags"] ?? 0)).map{Int($0)&1 != 0})==true}
        let maximumCount=try number(raw["maxcount"] ?? 100) * multiplier("count")
        try require((0...2048).contains(maximumCount),"Particle count exceeds 2048 sprites.")
        result.maximumCount=Int(maximumCount)
        result.preRoll=try number(raw["starttime"] ?? 0)
        guard let emitters=raw["emitter"] as? [[String:Any]],emitters.count==1,let emitter=emitters.first,
              let name=emitter["name"] as? String,let kind=SceneSpriteParticleSystem.Emitter(rawValue:name) else {throw SceneWallpaperFailure(message:"Only one sphere/box sprite emitter is supported.")}
        try require(Set(emitter.keys).isSubset(of:["id","name","rate","distancemin","distancemax","directions","origin","flags"]),"Particle emitter flags/behavior are unsupported.")
        try require((try? vector(emitter["origin"] ?? "0 0 0")) == .init(x:0,y:0,z:0),"Nonzero particle emitter origin is unsupported.")
        if let flags=emitter["flags"] {try require([0.0,2.0].contains(try number(flags)),"Unsupported emitter flags.")}
        result.emitter=kind;result.rate=try number(emitter["rate"] ?? 1) * multiplier("rate")
        if (try? number(emitter["flags"] ?? 0))==2 {try require(result.rate<=60,"Limit-one-per-frame particle emitters above 60 Hz are unsupported.")}
        result.directions=try vector(emitter["directions"] ?? "1 1 0")
        if kind == .sphererandom {
            result.radiusMin=try number(emitter["distancemin"] ?? 0);result.radiusMax=try number(emitter["distancemax"] ?? 0)
        } else {
            result.boxMax=try vector(emitter["distancemax"] ?? "0 0 0")
            result.boxMin=try vector(emitter["distancemin"] ?? "\(-result.boxMax.x) \(-result.boxMax.y) 0")
        }
        guard let initializers=raw["initializer"] as? [[String:Any]],let operators=raw["operator"] as? [[String:Any]],let renderers=raw["renderer"] as? [[String:Any]],renderers.count==1,let renderer=renderers.first else {throw SceneWallpaperFailure(message:"Invalid particle initializer/operator/renderer arrays.")}
        guard let rendererName=renderer["name"] as? String,let rendererKind=SceneSpriteParticleSystem.Renderer(rawValue:rendererName) else {throw SceneWallpaperFailure(message:"Unsupported particle renderer.")}
        try require(Set(renderer.keys).isSubset(of:["id","name","length","maxlength","minlength","subdivision","uvscale","uvscrolling","uvsmoothing","flags"]),"Unsupported particle renderer parameter.")
        result.renderer=rendererKind
        result.trailLength=try number(renderer["length"] ?? 1);result.trailMax=try number(renderer["maxlength"] ?? 2)
        if let minimum=renderer["minlength"],!(minimum is NSNull) {result.trailMin=try number(minimum)}
        let subdivision=try number(renderer["subdivision"] ?? 0);try require((0...8).contains(subdivision) && subdivision.rounded()==subdivision,"Unsafe rope subdivision.");result.subdivision=Int(subdivision)
        result.uvScale=try number(renderer["uvscale"] ?? 1);result.uvScrolling=try boolean(renderer["uvscrolling"] ?? false)
        if let smooth=renderer["uvsmoothing"] {try require(!(try boolean(smooth)) || result.uvScrolling,"Rope UV smoothing without UV scrolling is unsupported.")}
        if let flags=renderer["flags"] {try require([0.0,1.0].contains(try number(flags)),"Unsupported particle orientation flags.")}
        var seen=Set<String>()
        for entry in initializers {
            guard let name=entry["name"] as? String,seen.insert(name).inserted else {throw SceneWallpaperFailure(message:"Duplicate/invalid particle initializer.")}
            let keys:Set<String>=name=="turbulentvelocityrandom" ? ["id","name","speedmin","speedmax","scale","offset","timescale","phasemin","phasemax"] : ["id","name","min","max"]
            try require(Set(entry.keys).isSubset(of:keys),"Unsupported particle initializer parameter.")
            switch name {
            case "lifetimerandom": result.lifetimeMin=try number(entry["min"] ?? 1) * multiplier("lifetime");result.lifetimeMax=try number(entry["max"] ?? entry["min"] ?? 1) * multiplier("lifetime")
            case "sizerandom": result.sizeMin=try number(entry["min"] ?? 10) * multiplier("size");result.sizeMax=try number(entry["max"] ?? entry["min"] ?? 10) * multiplier("size")
            case "velocityrandom":
                let a=try vector(entry["min"] ?? "0 0 0"),b=try vector(entry["max"] ?? entry["min"] ?? "0 0 0"),m=try multiplier("speed")
                result.velocityMin = .init(x:a.x*m,y:a.y*m,z:a.z*m);result.velocityMax = .init(x:b.x*m,y:b.y*m,z:b.z*m)
            case "colorrandom":
                let a=try vector(entry["min"] ?? "255 255 255"),b=try vector(entry["max"] ?? entry["min"] ?? "255 255 255")
                result.colorMin = .init(x:a.x/255,y:a.y/255,z:a.z/255);result.colorMax = .init(x:b.x/255,y:b.y/255,z:b.z/255)
            case "alpharandom": result.alphaMin=try number(entry["min"] ?? 1) * multiplier("alpha");result.alphaMax=try number(entry["max"] ?? entry["min"] ?? 1) * multiplier("alpha")
            case "turbulentvelocityrandom":
                result.turbulentSpeedMin=try number(entry["speedmin"] ?? 0) * multiplier("speed");result.turbulentSpeedMax=try number(entry["speedmax"] ?? 1) * multiplier("speed")
                result.turbulentScale=try number(entry["scale"] ?? 0.1);result.turbulentTimeScale=try number(entry["timescale"] ?? 0.5);result.turbulentOffset=try number(entry["offset"] ?? 0)
                result.initialPhaseMin=try number(entry["phasemin"] ?? 0);result.initialPhaseMax=try number(entry["phasemax"] ?? 0)
            case "rotationrandom":
                let a=try vector(entry["min"] ?? "0 0 0"),b=try vector(entry["max"] ?? "0 0 0")
                try require(a.x==0 && a.y==0 && b.x==0 && b.y==0,"3D particle rotation is unsupported.")
                result.rotationMin=a.z;result.rotationMax=b.z
            default: throw SceneWallpaperFailure(message:"Unsupported particle initializer: \(name)")
            }
        }
        seen=[]
        for entry in operators {
            guard let name=entry["name"] as? String,seen.insert(name).inserted else {throw SceneWallpaperFailure(message:"Duplicate/invalid particle operator.")}
            let common:Set<String>=["id","name"]
            switch name {
            case "movement":
                try require(Set(entry.keys).isSubset(of:common.union(["drag","gravity"])),"Unsupported movement parameter.")
                result.drag=try number(entry["drag"] ?? 0);result.gravity=try vector(entry["gravity"] ?? "0 0 0")
            case "alphafade":
                try require(Set(entry.keys).isSubset(of:common.union(["fadeintime","fadeouttime"])),"Unsupported alpha-fade parameter.")
                result.fadeIn=try number(entry["fadeintime"] ?? 0.1);result.fadeOut=try number(entry["fadeouttime"] ?? 0.9)
            case "turbulence":
                try require(Set(entry.keys).isSubset(of:common.union(["scale","speedmin","speedmax","timescale","phasemin","phasemax","mask"])),"Unsupported turbulence parameter.")
                result.turbulenceSpeedMin=try number(entry["speedmin"] ?? 0);result.turbulenceSpeedMax=try number(entry["speedmax"] ?? 1);result.turbulenceTimeScale=try number(entry["timescale"] ?? 1);result.turbulencePhaseMin=try number(entry["phasemin"] ?? 0);result.turbulencePhaseMax=try number(entry["phasemax"] ?? 0);result.turbulenceMask=try vector(entry["mask"] ?? "1 1 0")
                if let scale=entry["scale"] {result.turbulentScale=try number(scale)}
            case "oscillatealpha":
                try require(Set(entry.keys).isSubset(of:common.union(["frequencymin","frequencymax","scalemin","scalemax"])),"Unsupported alpha oscillator parameter.")
                result.oscillateFrequencyMin=try number(entry["frequencymin"] ?? 0);result.oscillateFrequencyMax=try number(entry["frequencymax"] ?? 1);result.oscillateAlphaMin=try number(entry["scalemin"] ?? 0);result.oscillateAlphaMax=try number(entry["scalemax"] ?? 1)
            case "controlpointattract":
                try require(Set(entry.keys).isSubset(of:common.union(["controlpoint","origin","scale","threshold"])),"Unsupported control-point force parameter.")
                try require((try? vector(entry["origin"] ?? "0 0 0")) == .init(x:0,y:0,z:0),"Nonzero force offset is unsupported.")
                result.controlPointAttract=try number(entry["scale"] ?? 0);result.controlPointThreshold=try number(entry["threshold"] ?? 64)
                let cp=try number(entry["controlpoint"] ?? 0)
                try require((0...7).contains(cp) && cp.rounded()==cp,"Invalid force control-point index.")
                let point=(raw["controlpoint"] as? [[String:Any]] ?? []).first{(try? number($0["id"]))==cp}
                let flags=try number(point?["flags"] ?? 0)
                try require(Int(flags)&2==0,"Static world-space control-point force is unsupported.")
                if let sequence=raw["sequencemultiplier"],!(sequence is NSNull) {result.sequenceMultiplier=try number(sequence)}
        result.controlPointFollowsMouse=Int(flags)&1 != 0
            case "sizechange":
                try require(Set(entry.keys).isSubset(of:common.union(["starttime","startvalue","endvalue"])),"Unsupported size-change parameter.")
                result.sizeStart=try number(entry["startvalue"] ?? 1);result.sizeEnd=try number(entry["endvalue"] ?? 0);result.sizeChangeStart=try number(entry["starttime"] ?? 0)
            case "colorchange":
                try require(Set(entry.keys).isSubset(of:common.union(["starttime","startvalue","endvalue"])),"Unsupported color-change parameter.")
                result.colorStart=try vector(entry["startvalue"] ?? "1 1 1");result.colorEnd=try vector(entry["endvalue"] ?? "1 1 1");result.colorChangeStart=try number(entry["starttime"] ?? 0)
            default: throw SceneWallpaperFailure(message:"Unsupported particle operator: \(name)")
            }
        }
        // Velocity is inert without a Movement operator in the authored engine.
        // This backend integrates nonzero velocity, so refuse that combination
        // until it explicitly models inert initialized velocity.
        try require(seen.contains("movement") || (result.velocityMin == .init(x:0,y:0,z:0) && result.velocityMax == .init(x:0,y:0,z:0) && result.turbulentSpeedMax==0),"Nonzero particle velocity without a movement operator is unsupported; unintended motion is refused.")
        // Alpha defaults still consume a per-instance override without an initializer.
        if !initializers.contains(where:{$0["name"] as? String == "alpharandom"}) {result.alphaMin=try multiplier("alpha");result.alphaMax=result.alphaMin}
        try result.validate()
        return result
    }
    private static func jsonValue(_ raw: Any) throws -> GWJSONValue {
        func validate(_ value: Any, depth: Int) throws {
            guard depth <= 16 else { throw SceneWallpaperFailure(message: "SceneScript property nesting exceeds limit.") }
            if let array = value as? [Any] {
                guard array.count <= 1_024 else { throw SceneWallpaperFailure(message: "SceneScript property array exceeds limit.") }
                for child in array { try validate(child,depth:depth+1) }
            } else if let object = value as? [String:Any] {
                guard object.count <= 128 else { throw SceneWallpaperFailure(message: "SceneScript property object exceeds limit.") }
                for child in object.values { try validate(child,depth:depth+1) }
            }
        }
        try validate(raw,depth:0)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(GWJSONValue.self, from: data)
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SceneWallpaperFailure(message: "Scene resource must be a JSON object.") }; return object
    }
    private static func number(_ raw: Any?) throws -> Double {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw SceneWallpaperFailure(message: "Expected finite Scene number.") }; return number.doubleValue
    }
    private static func boolean(_ raw: Any) throws -> Bool {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw SceneWallpaperFailure(message: "Expected Scene boolean.") }; return value.boolValue
    }
    private static func vector(_ raw: Any) throws -> SceneVector3 {
        let values: [Double]
        if let string = raw as? String { let pieces = string.split(whereSeparator: \.isWhitespace); values = pieces.compactMap { Double($0) }; guard values.count == pieces.count else { throw SceneWallpaperFailure(message: "Invalid Scene vector text.") } }
        else if let scalar = try? number(raw) { values = [scalar,scalar,scalar] }
        else { throw SceneWallpaperFailure(message: "Unsupported Scene vector representation.") }
        guard (2...3).contains(values.count), values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw SceneWallpaperFailure(message: "Scene vector must contain 2/3 finite components.") }
        return SceneVector3(x: values[0],y: values[1],z: values.count == 3 ? values[2] : 0)
    }
    private static func rejectScripts(_ raw: Any, path: String, depth: Int, allowedWrappers: Set<String>, report: (String,String)->Void) throws {
        guard depth <= 32 else { throw SceneWallpaperFailure(message: "Scene JSON nesting exceeds limit.") }
        if let object = raw as? [String: Any] {
            for (key,value) in object {
                if allowedWrappers.contains(path) && (key == "script" || key == "scriptproperties") { continue }
                if key.lowercased().contains("script") { report(path + "." + key, "SceneScript is not executed.") }
                try rejectScripts(value,path: path + "." + key,depth: depth + 1,allowedWrappers: allowedWrappers,report: report)
            }
        } else if let array = raw as? [Any] { for (index,value) in array.enumerated() { try rejectScripts(value,path: path + "[\(index)]",depth: depth + 1,allowedWrappers: allowedWrappers,report: report) } }
    }
}
