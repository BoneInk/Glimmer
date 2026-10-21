import Foundation

/// Serializable data only. Source is inline JavaScript, never an implicit path.
struct SceneScriptBindingSpec: Codable, Sendable {
    let id: String
    let layerID: Int
    let target: String
    let source: String
    let initialValue: GWJSONValue
    let scriptProperties: [String: GWJSONValue]
    let scriptPropertyBindings: [String: String]
    init(id: String, layerID: Int, target: String, source: String, initialValue: GWJSONValue,
         scriptProperties: [String: GWJSONValue], scriptPropertyBindings: [String: String] = [:]) {
        self.id = id; self.layerID = layerID; self.target = target; self.source = source
        self.initialValue = initialValue; self.scriptProperties = scriptProperties; self.scriptPropertyBindings = scriptPropertyBindings
    }
    private enum CodingKeys: String, CodingKey { case id,layerID,target,source,initialValue,scriptProperties,scriptPropertyBindings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self,forKey:.id); layerID = try values.decode(Int.self,forKey:.layerID)
        target = try values.decode(String.self,forKey:.target); source = try values.decode(String.self,forKey:.source)
        initialValue = try values.decode(GWJSONValue.self,forKey:.initialValue)
        scriptProperties = try values.decode([String:GWJSONValue].self,forKey:.scriptProperties)
        scriptPropertyBindings = try values.decodeIfPresent([String:String].self,forKey:.scriptPropertyBindings) ?? [:]
    }
}

struct SceneScriptLayerState: Codable, Sendable {
    let id: Int
    let name: String
    let origin: SceneVector3
    let angles: SceneVector3
    let scale: SceneVector3
    let size: SceneVector2
    let color: SceneVector3
    let alpha: Double
    let visible: Bool
    let parentID: Int?
    let isTransformOnly: Bool
    let text: String?

    init(id: Int, name: String, origin: SceneVector3, angles: SceneVector3, scale: SceneVector3,
         size: SceneVector2, color: SceneVector3, alpha: Double, visible: Bool,
         parentID: Int? = nil, isTransformOnly: Bool = false, text: String? = nil) {
        self.id = id; self.name = name; self.origin = origin; self.angles = angles; self.scale = scale
        self.size = size; self.color = color; self.alpha = alpha; self.visible = visible
        self.parentID = parentID; self.isTransformOnly = isTransformOnly; self.text = text
    }
    init(layer: SceneImageLayer) {
        self.init(id: layer.id, name: layer.name, origin: layer.origin, angles: layer.anglesDegrees,
            scale: layer.scale, size: layer.size, color: layer.tint, alpha: layer.opacity, visible: layer.isVisible,
            parentID: layer.parentID, isTransformOnly: layer.isTransformOnly, text: layer.textLayer?.value)
    }
    private enum CodingKeys: String,CodingKey {case id,name,origin,angles,scale,size,color,alpha,visible,parentID,isTransformOnly,text}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try c.decode(Int.self,forKey:.id),name:try c.decode(String.self,forKey:.name),
            origin:try c.decode(SceneVector3.self,forKey:.origin),angles:try c.decode(SceneVector3.self,forKey:.angles),
            scale:try c.decode(SceneVector3.self,forKey:.scale),size:try c.decode(SceneVector2.self,forKey:.size),
            color:try c.decode(SceneVector3.self,forKey:.color),alpha:try c.decode(Double.self,forKey:.alpha),visible:try c.decode(Bool.self,forKey:.visible),
            parentID:try c.decodeIfPresent(Int.self,forKey:.parentID),isTransformOnly:try c.decodeIfPresent(Bool.self,forKey:.isTransformOnly) ?? false,
            text:try c.decodeIfPresent(String.self,forKey:.text))
    }

    func validate() throws {
        let components = [origin.x,origin.y,origin.z,angles.x,angles.y,angles.z,scale.x,scale.y,scale.z,size.x,size.y]
        guard id >= 0, id <= Int(Int32.max), name.utf8.count <= 4_096,
              parentID == nil || (parentID! >= 0 && parentID! <= Int(Int32.max) && parentID != id),
              components.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              origin.z == 0, angles.x == 0, angles.y == 0, scale.z == 1,
              size.x > 0, size.y > 0, alpha.isFinite, (0...1).contains(alpha),
              [color.x,color.y,color.z].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw SceneWallpaperFailure(message: "SceneScript returned an invalid, unbounded or non-2D layer state.")
        }
        if let text, text.utf8.count > 4_096 || text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
        }) {
            throw SceneWallpaperFailure(message:"SceneScript returned invalid or oversized text.")
        }
        if isTransformOnly, size != .init(x:1,y:1) || color != .init(x:1,y:1,z:1) || alpha != 1 || text != nil {
            throw SceneWallpaperFailure(message:"SceneScript cannot change transform-only layer image fields.")
        }
    }
}

struct SceneScriptDirectBindingSpec: Codable, Sendable {
    let layerID: Int
    let target: String
    let propertyKey: String
}

struct SceneScriptProgram: Codable, Sendable {
    let bindings: [SceneScriptBindingSpec]
    let layers: [SceneScriptLayerState]
    let directBindings: [SceneScriptDirectBindingSpec]
    /// Bounded project-relative source snapshot; only the worker resolves imports.
    let modules: [String: String]
    init(bindings: [SceneScriptBindingSpec], layers: [SceneScriptLayerState], directBindings: [SceneScriptDirectBindingSpec] = [], modules: [String: String] = [:]) {
        self.bindings = bindings; self.layers = layers; self.directBindings = directBindings; self.modules = modules
    }
    private enum CodingKeys: String, CodingKey { case bindings,layers,directBindings,modules }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try values.decode([SceneScriptBindingSpec].self,forKey:.bindings)
        layers = try values.decode([SceneScriptLayerState].self,forKey:.layers)
        directBindings = try values.decodeIfPresent([SceneScriptDirectBindingSpec].self,forKey:.directBindings) ?? []
        modules = try values.decodeIfPresent([String:String].self,forKey:.modules) ?? [:]
    }
    init(inspection: SceneWallpaperInspection) {
        bindings = inspection.scriptProgram?.bindings ?? []
        modules = inspection.scriptProgram?.modules ?? [:]
        layers = inspection.layers.map(SceneScriptLayerState.init(layer:))
        directBindings = inspection.layers.flatMap { layer in
            layer.bindings.map { SceneScriptDirectBindingSpec(layerID: layer.id,target: $0.target,propertyKey: $0.propertyKey) }
        }
    }
}

struct SceneScriptFrame: Codable, Sendable {
    let layers: [SceneScriptLayerState]
    let hasUpdateHandlers: Bool
    let canApplyUserProperties: Bool
}

extension SceneWallpaperInspection {
    /// Treat helper output as untrusted. Preserve all original dependencies,
    /// texture identities, layer ordering and metadata; accept only 2D values.
    func applyingScriptFrame(_ frame: SceneScriptFrame) throws -> SceneWallpaperInspection {
        guard isRenderableSubset, frame.layers.count == layers.count,
              frame.layers.count <= 512, Set(frame.layers.map(\.id)).count == frame.layers.count,
              Set(frame.layers.map(\.id)) == Set(layers.map(\.id)) else {
            throw SceneWallpaperFailure(message: "SceneScript frame layer IDs do not match the inspected scene.")
        }
        let states = Dictionary(uniqueKeysWithValues: frame.layers.map { ($0.id,$0) })
        let updated = try layers.map { layer -> SceneImageLayer in
            guard let state = states[layer.id], state.name == layer.name, state.isTransformOnly == layer.isTransformOnly else {
                throw SceneWallpaperFailure(message: "SceneScript cannot replace layer metadata or dependencies.")
            }
            try state.validate()
            guard (layer.textLayer != nil) == (state.text != nil) else {
                throw SceneWallpaperFailure(message:"SceneScript cannot add or remove text capability from a layer.")
            }
            let updatedText = layer.textLayer.map { original in
                SceneTextLayer(value: state.text!, fontData: original.fontData, pointSize: original.pointSize,
                    padding: original.padding, horizontalAlignment: original.horizontalAlignment,
                    verticalAlignment: original.verticalAlignment)
            }
            return SceneImageLayer(id: layer.id,name: layer.name,modelPath: layer.modelPath,materialPath: layer.materialPath,
                texturePath: layer.texturePath,origin: state.origin,anglesDegrees: state.angles,scale: state.scale,size: state.size,
                tint: state.color,opacity: state.alpha,isVisible: state.visible,bindings: layer.bindings,
                parentID:state.parentID,isTransformOnly:layer.isTransformOnly,blend:layer.blend,particleSystem:layer.particleSystem,
                lightShaft:layer.lightShaft,normalTexturePath:layer.normalTexturePath,refractionAmount:layer.refractionAmount,
                colorKey:layer.colorKey,parallaxDepth:layer.parallaxDepth,textLayer:updatedText)
        }
        try SceneHierarchy.validate(layers:updated)
        return SceneWallpaperInspection(canvasSize: canvasSize,clearColor: clearColor,camera:camera,layers: updated,
            textures: textures,diagnostics: diagnostics,scriptProgram: scriptProgram,bloom:bloom,
            fidelityNotes:fidelityNotes,renderIdentity:renderIdentity,parallax:parallax)
    }
}

/// Extraction policy only, not a JavaScript compiler or capability detector.
/// Actual exports and supported APIs are discovered by the isolated worker.
enum SceneScriptSourcePolicy {
    static let maximumSourceBytes = 256 * 1024
    static let maximumTotalSourceBytes = 1024 * 1024
    static let maximumBindings = 64
    static func validateInline(_ source: String) throws {
        guard !source.isEmpty, source.utf8.count <= maximumSourceBytes, !source.contains("\0") else {
            throw SceneWallpaperFailure(message: "SceneScript source is empty, contains NUL or exceeds 256 KiB.")
        }
    }
}
