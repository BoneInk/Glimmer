/// The draws of a Puppet Warp rig with clipping masks (`MDLClippingMask`; docs/models-plan.md
/// §2.13a), as WE plans them (0x14020b3b0…0x14020c6dc) and draws them (0x140208870…0x140208c10).
///
/// WE makes one part per range in the order they draw and marks each: clipped by a mask, a
/// masking part, or clipped by a mask that draws in place. It then walks the parts in order. A
/// part that isn't clipped joins the pending draw unless a "Hide mask geometry" mask masks it. At a
/// masking part that is the last one of a mask (the latest of the mask's own and its parents'),
/// the pending draw is drawn, then the mask: its coverage into `_rt_FullAlphaMask` and the
/// mask's clipped parts through it. A mask that draws in place draws its clipped parts where the
/// first of them comes instead. A clipped part draws nowhere else.
///
/// A mask's coverage is drawn through every part from its first masking part to its last, but
/// not its own clipped parts, with `materials/util/clippingmaskimage4.json`: red is the mask
/// texture where the part is opaque, so a part between the masking ones that isn't painted
/// covers the mask (its alpha raised to the 4th power, "Reduce alpha for overlapping parts that
/// are not masked"). A nested mask (`MDLClippingMask.parent`) intersects its coverage with its
/// parents' (0x140208a19: each drawn into `_rt_FullAlphaMaskIntermediate` and composed).
struct ScenePuppetClipping: Equatable {
    /// One mask's coverage, drawn through `ranges`.
    struct Layer: Equatable {
        var mask: Int
        var ranges: [Int]
    }

    enum Step: Equatable {
        /// Ranges drawn as the layer's material draws them.
        case draw([Int])
        /// `clipped` drawn through the coverage of every layer (the mask, then its parents),
        /// additive or translucent (the record's +0x40, which WE sets on the clipped draw's
        /// material, 0x140208b8f).
        case clip(layers: [Layer], clipped: [Int], additive: Bool)
    }

    let masks: [MDLClippingMask]
    let ranges: [MDLMesh.BoneRange]

    /// nil for a mesh without masks, or whose masks name ranges it doesn't have.
    init?(mesh: MDLMesh, boneCount: Int) {
        let masks = MDLClippingMask.masks(of: mesh)
        guard !masks.isEmpty, let ranges = mesh.boneRanges(boneCount: boneCount),
              masks.allSatisfy({ ($0.clippedRanges + $0.maskRanges).allSatisfy { $0 < ranges.count } }) else { return nil }
        self.init(masks: masks, ranges: ranges)
    }

    init(masks: [MDLClippingMask], ranges: [MDLMesh.BoneRange]) {
        self.masks = masks
        self.ranges = ranges
    }

    /// The ranges in drawing order: `drawRanges`'s (`ScenePuppetPose.drawRanges`, which merges
    /// adjacent ranges) taken apart, or the index buffer's order without them. A range none of
    /// them covers (an empty one) comes last.
    func order(_ drawRanges: [ScenePuppetDrawOrder.Range]?) -> [Int] {
        let byStart = ranges.indices.sorted { ranges[$0].firstIndex != ranges[$1].firstIndex
            ? ranges[$0].firstIndex < ranges[$1].firstIndex : $0 < $1 }
        guard let drawRanges else { return byStart }
        var out: [Int] = [], taken = Set<Int>()
        for draw in drawRanges {
            let end = draw.firstIndex + draw.indexCount
            for index in byStart where !taken.contains(index) && ranges[index].indexCount > 0
                && ranges[index].firstIndex >= draw.firstIndex && ranges[index].firstIndex + ranges[index].indexCount <= end {
                out.append(index)
                taken.insert(index)
            }
        }
        return out + byStart.filter { !taken.contains($0) }
    }

    /// WE's plan for the parts in `order` (range indices, first drawn first).
    func steps(order: [Int]) -> [Step] {
        let clippedAny = Set(masks.flatMap(\.clippedRanges))
        let maskingAny = Set(masks.flatMap(\.maskRanges))
        let inPlace = Set(masks.filter { $0.flags.contains(.drawsInPlace) }.flatMap(\.clippedRanges))

        // Per mask (0x14020b840): its clipped parts, its first and last masking part, the parts
        // hidden by it, and the parts its coverage is drawn through.
        struct Record {
            var mask: Int
            var clipped: [Int] = []
            var first = -1
            var last = -1
            var span: [Int] = []
        }
        var records: [Record] = []
        var hidden = Set<Int>()
        var maskOfPart: [Int: Int] = [:]
        for (index, mask) in masks.enumerated() {
            var record = Record(mask: index)
            let clipped = Set(mask.clippedRanges), masking = Set(mask.maskRanges)
            for (part, range) in order.enumerated() {
                if clippedAny.contains(range), clipped.contains(range) {
                    record.clipped.append(part)
                    maskOfPart[part] = index
                }
                if masking.contains(range) {
                    if record.first < 0 { record.first = part }
                    record.last = part
                    if mask.flags.contains(.hidesMaskGeometry) { hidden.insert(part) }
                }
            }
            if record.first >= 0 {
                let clippedParts = Set(record.clipped)
                record.span = (record.first...record.last).filter { !clippedParts.contains($0) }
            }
            records.append(record)
        }
        // 0x14020bc33: a mask is drawn after its parents' masking parts too.
        for index in records.indices {
            var parent = masks[index].parent
            while let current = parent {
                records[index].last = max(records[index].last, records[current].last)
                parent = masks[current].parent
            }
        }
        // 0x14020bcd7: by their first clipped part.
        let sorted = records.indices.sorted { a, b in
            let fa = records[a].clipped.first ?? Int.max, fb = records[b].clipped.first ?? Int.max
            return fa != fb ? fa < fb : a < b
        }

        var steps: [Step] = []
        var pending: [Int] = []
        func flush() {
            if !pending.isEmpty { steps.append(.draw(pending.map { order[$0] })) }
            pending = []
        }
        func clip(_ record: Record, parts: [Int]) {
            var layers = [Layer(mask: record.mask, ranges: record.span.map { order[$0] })]
            var parent = masks[record.mask].parent
            while let current = parent {
                layers.append(Layer(mask: current, ranges: records[current].span.map { order[$0] }))
                parent = masks[current].parent
            }
            steps.append(.clip(layers: layers, clipped: parts.map { order[$0] },
                               additive: masks[record.mask].flags.contains(.additive)))
        }
        var drawnInPlace = Set<Int>()
        for (part, range) in order.enumerated() {
            let isClipped = clippedAny.contains(range)
            if !isClipped, !hidden.contains(part) { pending.append(part) }
            if maskingAny.contains(range) {
                for index in sorted where !masks[index].flags.contains(.drawsInPlace) && records[index].last == part {
                    flush()
                    clip(records[index], parts: records[index].clipped)
                }
            } else if isClipped, inPlace.contains(range), !drawnInPlace.contains(part), let mask = maskOfPart[part] {
                // 0x14020c12a: the run of following parts clipped by the same mask draws with it.
                // WE starts a run again at each of them [I: drawn once here].
                var run = [part]
                var next = part + 1
                while next < order.count, maskOfPart[next] == mask, inPlace.contains(order[next]) {
                    run.append(next)
                    next += 1
                }
                drawnInPlace.formUnion(run)
                flush()
                clip(records[mask], parts: run)
            }
        }
        flush()
        return steps
    }

    /// `rangeIndices` as index ranges, adjacent ones merged into one draw.
    func drawRanges(_ rangeIndices: [Int]) -> [ScenePuppetDrawOrder.Range] {
        var out: [ScenePuppetDrawOrder.Range] = []
        for index in rangeIndices where ranges[index].indexCount > 0 {
            let range = ranges[index]
            if let last = out.last, last.firstIndex + last.indexCount == range.firstIndex {
                out[out.count - 1].indexCount += range.indexCount
            } else {
                out.append(.init(firstIndex: range.firstIndex, indexCount: range.indexCount))
            }
        }
        return out
    }

    /// Every range the steps draw in the layer's own image, in their order (the clipped ones
    /// unclipped): what the posed mesh lays another texture out with (`ScenePuppetRenderer.warp`).
    func visibleRanges(order: [Int]) -> [ScenePuppetDrawOrder.Range] {
        drawRanges(steps(order: order).flatMap { step -> [Int] in
            switch step {
            case .draw(let ranges): ranges
            case .clip(_, let clipped, _): clipped
            }
        })
    }
}
