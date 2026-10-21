import Foundation

/// How an export batch runs its items (the Android packages, the Live Photos): the ones that
/// render on the GPU one at a time, in order, and the file-only work beside them,
/// `fileConcurrency` at once.
enum ExportLanes {
    @MainActor
    static func run(gpu: [Int], files: [Int], fileConcurrency: Int, _ work: @escaping @MainActor (Int) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for index in gpu { await work(index) }
            }
            group.addTask { @MainActor in
                await withTaskGroup(of: Void.self) { lane in
                    var pending = files.makeIterator()
                    for _ in 0..<max(fileConcurrency, 1) {
                        guard let index = pending.next() else { break }
                        lane.addTask { @MainActor in await work(index) }
                    }
                    while await lane.next() != nil {
                        guard let index = pending.next() else { continue }
                        lane.addTask { @MainActor in await work(index) }
                    }
                }
            }
        }
    }
}

/// Where one item of an export batch is.
enum ExportItemStatus: Equatable {
    case waiting, running, done, failed(String), cancelled
}
