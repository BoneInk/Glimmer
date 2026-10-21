import Foundation

/// The min-cut graph GrabCut solves: Boykov and Kolmogorov's max-flow (search trees grown from
/// both terminals, augmented, orphans adopted), as OpenCV's `GCGraph` runs it for `cv::grabCut`.
/// Vertices carry their terminal capacity (positive: from the source, negative: to the sink);
/// edges come in pairs, an edge `e` and its reverse `e ^ 1`, from index 2.
struct MaxFlowGraph {
    private var first: [Int32]
    private var terminal: [Float]
    private var edgeTarget: [Int32] = [0, 0]
    private var edgeNext: [Int32] = [0, 0]
    private var edgeCapacity: [Float] = [0, 0]
    private(set) var flow: Double = 0
    /// After `maxFlow`: 0 for a vertex on the source's side.
    private var tree: [UInt8]

    init(vertices: Int, edgesHint: Int = 0) {
        first = [Int32](repeating: 0, count: vertices)
        terminal = [Float](repeating: 0, count: vertices)
        tree = [UInt8](repeating: 0, count: vertices)
        edgeTarget.reserveCapacity(edgesHint * 2 + 2)
        edgeNext.reserveCapacity(edgesHint * 2 + 2)
        edgeCapacity.reserveCapacity(edgesHint * 2 + 2)
    }

    var vertexCount: Int { first.count }

    /// `addTermWeights`: capacities from the source and to the sink.
    mutating func addTerminalWeights(_ vertex: Int, source: Float, sink: Float) {
        var source = source, sink = sink
        let existing = terminal[vertex]
        if existing > 0 { source += existing } else { sink -= existing }
        flow += Double(min(source, sink))
        terminal[vertex] = source - sink
    }

    /// `addEdges`: `i → j` with `weight`, `j → i` with `reverse`.
    mutating func addEdges(_ i: Int, _ j: Int, weight: Float, reverse: Float) {
        let forward = Int32(edgeTarget.count)
        edgeTarget.append(Int32(j))
        edgeNext.append(first[i])
        edgeCapacity.append(weight)
        first[i] = forward
        edgeTarget.append(Int32(i))
        edgeNext.append(first[j])
        edgeCapacity.append(reverse)
        first[j] = forward + 1
    }

    func isOnSourceSide(_ vertex: Int) -> Bool { tree[vertex] == 0 }

    /// Runs the max-flow; returns the flow.
    @discardableResult
    mutating func maxFlow() -> Double {
        let count = first.count
        let terminalParent: Int32 = -1, orphanParent: Int32 = -2
        let nilNode = count
        // `next` links the active vertices (nil-terminated by `nilNode`); -1 is "not queued".
        var next = [Int](repeating: -1, count: count + 1)
        var parent = [Int32](repeating: 0, count: count)
        var timestamp = [Int](repeating: 0, count: count)
        var distance = [Int](repeating: 0, count: count)
        var orphans: [Int] = []
        var head = nilNode, tail = nilNode
        func enqueue(_ v: Int) {
            next[v] = nilNode
            if head == nilNode { head = v } else { next[tail] = v }
            tail = v
        }
        for v in 0..<count {
            if terminal[v] != 0 {
                enqueue(v)
                distance[v] = 1
                parent[v] = terminalParent
                tree[v] = terminal[v] < 0 ? 1 : 0
            } else {
                parent[v] = 0
            }
        }
        var currentTime = 0
        while true {
            // Grow the trees until they touch.
            var bridge: Int32 = -1
            while head != nilNode {
                let v = head
                if parent[v] != 0 {
                    let vt = Int32(tree[v])
                    var edge = first[v]
                    while edge != 0 {
                        defer { edge = edgeNext[Int(edge)] }
                        if edgeCapacity[Int(edge ^ vt)] == 0 { continue }
                        let u = Int(edgeTarget[Int(edge)])
                        if parent[u] == 0 {
                            tree[u] = UInt8(vt)
                            parent[u] = edge ^ 1
                            timestamp[u] = timestamp[v]
                            distance[u] = distance[v] + 1
                            if next[u] < 0 { enqueue(u) }
                            continue
                        }
                        if Int32(tree[u]) != vt {
                            bridge = edge ^ vt
                            break
                        }
                        if distance[u] > distance[v] + 1 && timestamp[u] <= timestamp[v] {
                            parent[u] = edge ^ 1
                            timestamp[u] = timestamp[v]
                            distance[u] = distance[v] + 1
                        }
                    }
                    if bridge > 0 { break }
                }
                head = next[v]
                next[v] = -1
                if head == nilNode { tail = nilNode }
            }
            if bridge <= 0 { break }

            // The bottleneck along the path through the bridge.
            var bottleneck = edgeCapacity[Int(bridge)]
            for side in [Int32(1), Int32(0)] {
                var v = Int(edgeTarget[Int(bridge ^ side)])
                while parent[v] >= 0 {
                    let edge = parent[v]
                    bottleneck = min(bottleneck, edgeCapacity[Int(edge ^ side)])
                    v = Int(edgeTarget[Int(edge)])
                }
                bottleneck = min(bottleneck, abs(terminal[v]))
            }
            // Push it.
            edgeCapacity[Int(bridge)] -= bottleneck
            edgeCapacity[Int(bridge ^ 1)] += bottleneck
            flow += Double(bottleneck)
            for side in [Int32(1), Int32(0)] {
                var v = Int(edgeTarget[Int(bridge ^ side)])
                while parent[v] >= 0 {
                    let edge = parent[v]
                    edgeCapacity[Int(edge ^ (side ^ 1))] += bottleneck
                    edgeCapacity[Int(edge ^ side)] -= bottleneck
                    if edgeCapacity[Int(edge ^ side)] == 0 {
                        orphans.append(v)
                        parent[v] = orphanParent
                    }
                    v = Int(edgeTarget[Int(edge)])
                }
                terminal[v] += bottleneck * Float(1 - Int(side) * 2)
                if terminal[v] == 0 {
                    orphans.append(v)
                    parent[v] = orphanParent
                }
            }

            // Adopt the orphans.
            currentTime += 1
            while let orphan = orphans.popLast() {
                let vt = Int32(tree[orphan])
                var minDistance = Int.max
                var best: Int32 = 0
                var edge = first[orphan]
                while edge != 0 {
                    defer { edge = edgeNext[Int(edge)] }
                    if edgeCapacity[Int(edge ^ (vt ^ 1))] == 0 { continue }
                    var u = Int(edgeTarget[Int(edge)])
                    if Int32(tree[u]) != vt || parent[u] == 0 { continue }
                    var d = 0
                    while true {
                        if timestamp[u] == currentTime {
                            d += distance[u]
                            break
                        }
                        let up = parent[u]
                        d += 1
                        if up < 0 {
                            if up == orphanParent {
                                d = Int.max - 1
                            } else {
                                timestamp[u] = currentTime
                                distance[u] = 1
                            }
                            break
                        }
                        u = Int(edgeTarget[Int(up)])
                    }
                    d += 1
                    if d < Int.max {
                        if d < minDistance {
                            minDistance = d
                            best = edge
                        }
                        var w = Int(edgeTarget[Int(edge)])
                        while timestamp[w] != currentTime {
                            timestamp[w] = currentTime
                            d -= 1
                            distance[w] = d
                            w = Int(edgeTarget[Int(parent[w])])
                        }
                    }
                }
                parent[orphan] = best
                if best > 0 {
                    timestamp[orphan] = currentTime
                    distance[orphan] = minDistance
                    continue
                }
                timestamp[orphan] = 0
                edge = first[orphan]
                while edge != 0 {
                    defer { edge = edgeNext[Int(edge)] }
                    let u = Int(edgeTarget[Int(edge)])
                    let up = parent[u]
                    if Int32(tree[u]) != vt || up == 0 { continue }
                    if edgeCapacity[Int(edge ^ (vt ^ 1))] != 0 && next[u] < 0 { enqueue(u) }
                    if up > 0 && Int(edgeTarget[Int(up)]) == orphan {
                        orphans.append(u)
                        parent[u] = orphanParent
                    }
                }
            }
        }
        return flow
    }
}
