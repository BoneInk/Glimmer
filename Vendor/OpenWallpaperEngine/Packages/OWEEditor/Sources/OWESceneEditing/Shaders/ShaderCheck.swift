import Foundation

/// A shader pair the shader editor asks the app's translator to translate, as the scene loader
/// would: the material's shader with the edited text in place of its file.
public struct ShaderCheckRequest: Hashable, Sendable {
    /// The material's `shader` (`effects/foo`), its files `shaders/<shader>.vert` and `.frag`.
    public var shader: String
    /// The effect's folder (`effects/foo`), searched first for the shader's files, as the loader
    /// searches a project's effect; empty for none.
    public var effectDirectory: String
    /// Files by path standing in for what the loader would read (the edited shader, the draft's
    /// other effect files).
    public var files: [String: String]
    /// Combos over the shaders' defaults (the material's, the layer's effect's).
    public var combos: [String: Int]

    public init(shader: String, effectDirectory: String, files: [String: String], combos: [String: Int] = [:]) {
        self.shader = shader
        self.effectDirectory = effectDirectory
        self.files = files
        self.combos = combos
    }
}

/// One problem the translator found, on a line of the edited file where it can tell.
public struct ShaderDiagnostic: Hashable, Sendable, Identifiable {
    public enum Stage: String, Sendable { case vertex = "vert", fragment = "frag" }

    public let stage: Stage
    /// 1-based, in the stage's own file; nil when the problem is in an included header, the
    /// engine's prelude or isn't on a line.
    public let line: Int?
    public let message: String

    public var id: String { "\(stage.rawValue):\(line ?? 0):\(message)" }

    public init(stage: Stage, line: Int?, message: String) {
        self.stage = stage
        self.line = line
        self.message = message
    }
}

/// What a check found: nothing for a pair that translates, else its problems and the text the
/// failing step compiled (WE's View Errors shows the translated source), with the line the
/// first problem is on in that text.
public struct ShaderCheckResult: Hashable, Sendable {
    public var diagnostics: [ShaderDiagnostic]
    /// The source the step that failed was given, as the compiler numbers its lines.
    public var translatedSource: String?
    /// The step that failed (`preprocess`, `glslang`, …).
    public var step: String?
    /// The first problem's line in `translatedSource`.
    public var translatedLine: Int?
    /// The whole error output, for View Errors.
    public var log: String

    public var isSuccess: Bool { diagnostics.isEmpty && log.isEmpty }

    public init(diagnostics: [ShaderDiagnostic] = [], translatedSource: String? = nil, step: String? = nil,
                translatedLine: Int? = nil, log: String = "") {
        self.diagnostics = diagnostics
        self.translatedSource = translatedSource
        self.step = step
        self.translatedLine = translatedLine
        self.log = log
    }

    public static let success = ShaderCheckResult()
}

/// The app's translator, as the shader editor uses it (the editor package can't link the
/// toolchain): a pair translated as the scene loader would, its problems on the edited lines.
public protocol ShaderChecking: Sendable {
    func check(_ request: ShaderCheckRequest) async -> ShaderCheckResult
}

/// Maps line numbers between two versions of a text (the shader as written and as a step of the
/// translator saw it): lines the two share map exactly, by a longest common subsequence of
/// lines; a changed line to the line it replaced, and a line only the later text has to the
/// nearest shared line before it.
public struct ShaderLineMap: Sendable {
    /// For each line of `to` (0-based), the line of `from` (0-based), or nil before any shared line.
    let mapping: [Int?]

    public init(from: [String], to: [String]) {
        var inserted = Set<Int>(), removed = Set<Int>()
        for change in to.difference(from: from) {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removed.insert(offset)
            }
        }
        var mapping: [Int?] = []
        var source = 0, target = 0
        var last: Int?
        while target < to.count {
            var removedRun = 0, insertedRun = 0
            while source + removedRun < from.count, removed.contains(source + removedRun) { removedRun += 1 }
            while target + insertedRun < to.count, inserted.contains(target + insertedRun) { insertedRun += 1 }
            if removedRun == 0 && insertedRun == 0 {
                mapping.append(source)
                last = source
                source += 1
                target += 1
                continue
            }
            // Changed lines pair with the lines they replaced, from the run's end; the run's
            // other new lines go with the shared line before them.
            for index in 0..<insertedRun {
                let paired = index - (insertedRun - removedRun)
                mapping.append(paired >= 0 ? source + paired : last)
            }
            source += removedRun
            target += insertedRun
        }
        self.mapping = mapping
    }

    /// The 1-based line of `from` for the 1-based line `line` of `to`.
    public func line(_ line: Int) -> Int? {
        guard line >= 1, line <= mapping.count, let mapped = mapping[line - 1] else { return nil }
        return mapped + 1
    }

    /// Whether `to`'s 1-based `line` is one `from` has as it is.
    public func isShared(_ line: Int, from: [String], to: [String]) -> Bool {
        guard let mapped = self.line(line), line <= to.count, mapped <= from.count else { return false }
        return from[mapped - 1] == to[line - 1]
    }
}
