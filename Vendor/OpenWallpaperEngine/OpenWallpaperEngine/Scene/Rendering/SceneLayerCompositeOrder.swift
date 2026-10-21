/// The layers whose image other layers' effects sample as `_rt_imageLayerComposite_<id>_a`, and
/// the order the renderer prepares layers in so each sampled layer is ready before its readers
/// (docs/models-plan.md §4.3, roadmap notes §8 item 14).
///
/// WE registers a layer's first composite buffer, its image after its effects, in the texture
/// manager under that name (0x1401ea7a3 → 0x1400d3198), so a material of another layer that names
/// it samples what the layer drew this frame; scene.json lists such layers in the reader's
/// `dependencies`. A sampled layer is prepared even when hidden (3378346807's clock is drawn only
/// into the composite a fullscreen layer blends), and before the layers that read it, whatever
/// their order in the list (2176097362's `blue` reads `alpha blue`, which comes later).
struct SceneLayerCompositeOrder {
    /// The ids of the layers some layer's effects sample.
    let sources: Set<String>
    /// Indices into the layer list: scene order, with every sampled layer moved before the first
    /// layer that reads it. A layer reading itself, or a cycle, reads nothing prepared this frame.
    let sequence: [Int]
    /// The layers that must run their effects inside the scene pass, in draw order, for their
    /// composites to be what WE's are: a sampled layer that reads the scene (`readingScene`) makes
    /// its image only once what lies beneath it is drawn, and a layer sampling it, directly or
    /// through another, then runs at its own place in the scene too. WE renders every object in
    /// scene order, its effects included, and registers its composite as it goes (0x1401ea7a3), so
    /// a reader drawn after the source sees this frame's image [I: a reader drawn before it sees
    /// the one its buffer kept from the last frame; here it sees none].
    let inScene: Set<String>

    /// `layers` in draw order, each with the ids its effects sample; `readingScene` are the ids of
    /// the layers that read the scene drawn beneath them.
    init(layers: [(id: String, samples: Set<String>)], readingScene: Set<String> = []) {
        var index: [String: Int] = [:]
        for (position, layer) in layers.enumerated() where index[layer.id] == nil { index[layer.id] = position }
        var sources = Set<String>()
        for layer in layers { sources.formUnion(layer.samples.filter { index[$0] != nil && $0 != layer.id }) }
        self.sources = sources
        var inScene = sources.intersection(readingScene)
        var grew = !inScene.isEmpty
        while grew {
            let readers = layers.filter { !inScene.contains($0.id) && !$0.samples.isDisjoint(with: inScene) }.map(\.id)
            inScene.formUnion(readers)
            grew = !readers.isEmpty
        }
        self.inScene = inScene
        guard !sources.isEmpty else {
            sequence = Array(layers.indices)
            return
        }
        var sequence: [Int] = []
        sequence.reserveCapacity(layers.count)
        var state = [UInt8](repeating: 0, count: layers.count) // 0 new, 1 visiting, 2 placed
        func place(_ position: Int) {
            guard state[position] == 0 else { return }
            state[position] = 1
            for dependency in layers[position].samples.compactMap({ index[$0] }).sorted() where dependency != position {
                place(dependency)
            }
            state[position] = 2
            sequence.append(position)
        }
        for position in layers.indices { place(position) }
        self.sequence = sequence
    }
}
