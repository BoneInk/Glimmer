import Foundation

/// The parameters and combos Scene Edit / Export shows for each effect file
/// (`SceneEffectParameters`), read from the wallpaper's files, else WE's assets, once per effect
/// file: a scene repeats the same effects on many layers, and each read parses every pass's shaders.
final class SceneInspectorEffectShaders {
    private let readFile: (String) -> Data?
    private var parameters: [String: [EffectShaderParameter]] = [:]
    private var combos: [String: [EffectShaderCombo]] = [:]

    convenience init(wallpaperDirectory: URL, assets: URL? = WallpaperEngineAssets.directory) {
        self.init { path in
            FileManager.default.contents(atPath: wallpaperDirectory.appending(path: path).path)
                ?? assets.flatMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }
        }
    }

    init(readFile: @escaping (String) -> Data?) {
        self.readFile = readFile
    }

    func parameters(for effectFile: String) -> [EffectShaderParameter] {
        if let cached = parameters[effectFile] { return cached }
        let read = SceneEffectParameters.parameters(for: effectFile, readFile: readFile)
        parameters[effectFile] = read
        return read
    }

    func combos(for effectFile: String) -> [EffectShaderCombo] {
        if let cached = combos[effectFile] { return cached }
        let read = SceneEffectParameters.combos(for: effectFile, readFile: readFile)
        combos[effectFile] = read
        return read
    }
}
