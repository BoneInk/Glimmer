import Foundation

/// Every user-property binding of a loaded scene, and the one place bound values are resolved.
///
/// Built during load: scene.json when it is read, and each JSON document the build pulls in (an
/// effect, material, particle system, model or font description, from the wallpaper, a Workshop
/// dependency or WE's assets) the first time it is read (`resolvedData`). Each `{"user": …}`
/// occurrence is recorded with its property, condition, authored value, document and JSON path,
/// the typed target it drives and what a change invalidates (`UserPropertyBindingClassifier`).
///
/// Parsers never see a binding they could drop: the documents they decode are the table's
/// resolution (`resolvedDocument`), with every bound `value` replaced by what the properties say,
/// and the binding itself kept for the sites that follow it live. A property change is looked up
/// here (`changes(for:)`) to decide what to update, per owner and class.
///
/// Thread-safe: loads and builds record, the main thread and the render loop read.
final class UserPropertyBindingTable {
    private let lock = NSLock()
    /// By document, in walk order (guarded by `lock`).
    private var bindingsByDocument: [UserPropertyBindingDocument: [UserPropertyBinding]] = [:]
    /// Every scene object whose build read each asset document (guarded by `lock`).
    private var assetOwners: [String: Set<UserPropertyBindingOwner>] = [:]
    /// The object being built, which owns the asset documents read meanwhile (guarded by `lock`).
    private var building: UserPropertyBindingOwner?

    init() {}

    // MARK: - Recording

    /// Records every binding of `json` as `document`, replacing what an earlier read of it recorded.
    func record(_ document: UserPropertyBindingDocument, json: SceneJSON) {
        let found = Self.bindings(in: json, document: document)
        lock.withLock {
            bindingsByDocument[document] = found
            if case .asset(let path) = document {
                assetOwners[path, default: []].insert(building ?? .scene)
                capturedReads?.insert(path)
            }
        }
    }

    /// Forgets every document (a new scene is loaded).
    func removeAll() {
        lock.withLock {
            bindingsByDocument.removeAll()
            assetOwners.removeAll()
            building = nil
        }
    }

    /// Runs `body` with `owner` owning the asset documents it reads.
    func building<T>(_ owner: UserPropertyBindingOwner, _ body: () -> T) -> T {
        let previous = lock.withLock { () -> UserPropertyBindingOwner? in
            let previous = building
            building = owner
            return previous
        }
        defer { lock.withLock { building = previous } }
        return body()
    }

    /// Links an asset document read earlier (a cached read) to the object being built.
    private func noteRead(_ path: String) {
        lock.withLock {
            assetOwners[path, default: []].insert(building ?? .scene)
            capturedReads?.insert(path)
        }
    }

    /// The asset documents `capturingReads` saw read (guarded by `lock`).
    private var capturedReads: Set<String>?

    /// Runs `body` and returns the asset documents it read, so a build that reuses what `body`
    /// built can link them to its own object (`noteReads`).
    func capturingReads<T>(_ body: () -> T) -> (T, Set<String>) {
        let outer = lock.withLock { () -> Set<String>? in
            defer { capturedReads = [] }
            return capturedReads
        }
        let result = body()
        let reads = lock.withLock { () -> Set<String> in
            let reads = capturedReads ?? []
            // A capture inside another one: the outer one saw these reads too.
            capturedReads = outer.map { $0.union(reads) }
            return reads
        }
        return (result, reads)
    }

    /// Links asset documents an earlier build read (`capturingReads`) to the object being built,
    /// as reading them again would.
    func noteReads(_ paths: Set<String>) {
        for path in paths { noteRead(path) }
    }

    // MARK: - Reading

    /// Every recorded binding.
    var all: [UserPropertyBinding] {
        lock.withLock { bindingsByDocument.values.flatMap { $0 } }
    }

    /// The recorded bindings of property `name`.
    func bindings(named name: String) -> [UserPropertyBinding] {
        lock.withLock { bindingsByDocument.values.flatMap { $0.filter { $0.name == name } } }
    }

    /// Whether `document` binds anything.
    func hasBindings(in document: UserPropertyBindingDocument) -> Bool {
        lock.withLock { !(bindingsByDocument[document] ?? []).isEmpty }
    }

    /// Whose state `binding` belongs to: its own owner in scene.json, every object that read an
    /// asset document.
    func owners(of binding: UserPropertyBinding) -> Set<UserPropertyBindingOwner> {
        guard case .asset(let path) = binding.site.document else { return [binding.owner] }
        return lock.withLock { assetOwners[path] ?? [.scene] }
    }

    // MARK: - Resolving

    /// The value the bound site at `site` takes with `properties`; nil when nothing is bound there.
    func resolve(_ site: UserPropertyBindingSite, properties: (String) -> String?) -> SceneJSON? {
        let binding = lock.withLock { bindingsByDocument[site.document]?.first { $0.site == site } }
        return binding.map { Self.value(of: $0, properties: properties) }
    }

    /// `binding`'s value: the property converted to the site's type, else the authored value.
    static func value(of binding: UserPropertyBinding, properties: (String) -> String?) -> SceneJSON {
        guard let text = properties(binding.name) else { return binding.defaultValue ?? .null }
        let value = UserPropertyValueConversion.siteValue(text, condition: binding.condition, default: binding.defaultValue)
        // A scalar property (a slider) bound to a scale or colour sets every axis or channel.
        guard binding.target == .objectField(.scale) || binding.target == .objectField(.color),
              case .string(let resolved) = value, let scalar = ShaderValue(string: resolved), scalar.components.count == 1,
              case .string(let authored)? = binding.defaultValue,
              let width = ShaderValue(string: authored)?.components.count, width > 1 else { return value }
        return .string(Array(repeating: resolved.trimmingCharacters(in: .whitespaces), count: width).joined(separator: " "))
    }

    /// `json` (the document recorded as `document`) with every bound `value` replaced by its
    /// resolution. `usershadervalues` entries stay: the material's constants bind to them.
    func resolvedDocument(_ json: SceneJSON, document: UserPropertyBindingDocument,
                          properties: (String) -> String?) -> SceneJSON {
        let bindings = lock.withLock { bindingsByDocument[document] ?? [] }
        var resolved = json
        for binding in bindings {
            if case .userShaderValue = binding.target { continue }
            resolved.setBoundValue(Self.value(of: binding, properties: properties), at: binding.site.path.components[...],
                                   replacing: binding.collapses)
        }
        return resolved
    }

    /// The bytes of the asset document at `path` as its parser should read them: recorded on first
    /// read, and resolved with `properties` when it binds anything. A `.tex` with texture variants
    /// is composed as the properties choose (`resolvedTexture`); other files that aren't JSON
    /// objects (textures, shaders, models) pass through untouched.
    func resolvedData(_ data: Data, path: String, properties: (String) -> String?) -> Data {
        if path.lowercased().hasSuffix(".tex") { return resolvedTexture(data, path: path, properties: properties) }
        guard path.lowercased().hasSuffix(".json"), data.range(of: Data("\"user".utf8)) != nil else { return data }
        let document = UserPropertyBindingDocument.asset(path)
        let recorded = lock.withLock { bindingsByDocument[document] != nil }
        let json: SceneJSON
        do {
            json = try decodeTolerant(SceneJSON.self, from: data)
        } catch {
            // Its parser reports the failure with the file's context.
            return data
        }
        if recorded { noteRead(path) } else { record(document, json: json) }
        guard lock.withLock({ !(bindingsByDocument[document] ?? []).isEmpty }) else { return data }
        do {
            return try JSONSerialization.data(withJSONObject: resolvedDocument(json, document: document,
                                                                               properties: properties).foundationObject)
        } catch {
            OWELog.error(.scene, "Can't write \(path) with its user properties resolved: \(error)")
            return data
        }
    }

    /// A `.tex` with texture variants (`TEXVariants`) with the options `properties` turn on composed
    /// in (`TEXVariantResolver`). Its conditions are recorded as the texture's bindings, so a change
    /// rebuilds every object that read it, as WE reloads the texture. Any other `.tex` as it is.
    private func resolvedTexture(_ data: Data, path: String, properties: (String) -> String?) -> Data {
        guard TEXVariants.declares(in: data), let variants = TEXVariants(texData: data) else { return data }
        let document = UserPropertyBindingDocument.asset(path)
        if lock.withLock({ bindingsByDocument[document] != nil }) {
            noteRead(path)
        } else {
            record(document, json: variants.bindingDocument)
        }
        return TEXVariantResolver.resolve(data, enabled: variants.enabled { $0.isMet(properties) }) ?? data
    }

    /// The build of `owner` baked `target` into a resource (a solid layer's colour is its image):
    /// its bindings become structural, so a change rebuilds the object.
    func baked(_ target: UserPropertyBindingTarget, of owner: UserPropertyBindingOwner) {
        lock.withLock {
            guard var bindings = bindingsByDocument[.scene] else { return }
            for index in bindings.indices where bindings[index].owner == owner && bindings[index].target == target
                && bindings[index].dependency < .structural {
                let binding = bindings[index]
                bindings[index] = UserPropertyBinding(name: binding.name, condition: binding.condition,
                                                      defaultValue: binding.defaultValue, site: binding.site,
                                                      target: binding.target, dependency: .structural, owner: binding.owner,
                                                      collapses: binding.collapses)
            }
            bindingsByDocument[.scene] = bindings
        }
    }

    // MARK: - Changes

    /// What changing the properties `names` invalidates: per owner, the heaviest class of the
    /// bindings that read them. Properties nothing binds are absent (only scripts read them).
    func changes(for names: Set<String>) -> [UserPropertyBindingOwner: UserPropertyBindingDependency] {
        var result: [UserPropertyBindingOwner: UserPropertyBindingDependency] = [:]
        for name in names {
            for binding in bindings(named: name) {
                for owner in owners(of: binding) {
                    result[owner] = max(result[owner] ?? binding.dependency, binding.dependency)
                }
            }
        }
        return result
    }

    // MARK: - Walking

    /// Every binding in `json`, in document order.
    static func bindings(in json: SceneJSON, document: UserPropertyBindingDocument) -> [UserPropertyBinding] {
        var found: [UserPropertyBinding] = []
        func walk(_ value: SceneJSON, path: UserPropertyBindingPath) {
            switch value {
            case .object(let fields):
                if let reference = UserReference(fields["user"]) {
                    let classified = UserPropertyBindingClassifier.classify(path, node: fields, document: document, root: json)
                    found.append(UserPropertyBinding(name: reference.name, condition: reference.condition,
                                                     defaultValue: fields["value"],
                                                     site: UserPropertyBindingSite(document: document, path: path),
                                                     target: classified.target, dependency: classified.dependency,
                                                     owner: classified.owner,
                                                     collapses: classified.dependency == .structural && fields["value"] != nil
                                                        && Set(fields.keys).isSubset(of: ["user", "value"])))
                }
                if case .object(let entries)? = fields["usershadervalues"] {
                    let constants: [String: SceneJSON]
                    if case .object(let values)? = fields["constantshadervalues"] { constants = values } else { constants = [:] }
                    for (property, key) in entries.sorted(by: { $0.key < $1.key }) {
                        guard case .string(let constant) = key else { continue }
                        let classified = UserPropertyBindingClassifier.userShaderValue(key: constant)
                        let site = UserPropertyBindingSite(document: document,
                                                           path: path.appending(.key("usershadervalues")).appending(.key(property)))
                        found.append(UserPropertyBinding(name: property, condition: nil, defaultValue: constants[constant],
                                                         site: site, target: classified.target,
                                                         dependency: classified.dependency, owner: classified.owner))
                    }
                }
                for key in fields.keys.sorted() where key != "user" && key != "usershadervalues" {
                    walk(fields[key]!, path: path.appending(.key(key)))
                }
            case .array(let values):
                for (index, element) in values.enumerated() { walk(element, path: path.appending(.index(index))) }
            default:
                break
            }
        }
        walk(json, path: UserPropertyBindingPath())
        return found
    }

    /// `"user": "<name>"` or `"user": {"name", "condition"}`; nil for `null` (WE's editor writes it
    /// on values that aren't bound) and anything else.
    private struct UserReference {
        let name: String
        let condition: String?

        init?(_ json: SceneJSON?) {
            switch json {
            case .string(let name)?:
                self.name = name
                condition = nil
            case .object(let fields)?:
                guard case .string(let name)? = fields["name"] else { return nil }
                self.name = name
                condition = fields["condition"]?.scalarString
            default:
                return nil
            }
        }
    }
}

extension SceneJSON {
    /// Sets `value` of the object at `path`, keeping its other keys (`user`, `script`, `animation`);
    /// with `replacing`, puts `value` in the object's place.
    mutating func setBoundValue(_ value: SceneJSON, at path: ArraySlice<UserPropertyBindingPath.Component>,
                                replacing: Bool = false) {
        guard let first = path.first else {
            if replacing {
                self = value
            } else if case .object(var fields) = self {
                fields["value"] = value
                self = .object(fields)
            }
            return
        }
        switch (first, self) {
        case (.key(let key), .object(var fields)):
            guard var child = fields[key] else { return }
            child.setBoundValue(value, at: path.dropFirst(), replacing: replacing)
            fields[key] = child
            self = .object(fields)
        case (.index(let index), .array(var values)):
            guard values.indices.contains(index) else { return }
            values[index].setBoundValue(value, at: path.dropFirst(), replacing: replacing)
            self = .array(values)
        default:
            return
        }
    }
}
