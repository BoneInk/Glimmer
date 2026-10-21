import Darwin
import Foundation
import OWEEditor
import OWESceneEditing

/// One lane of the background pre-warm (`EditorPreviewPrewarm`): renders one preview at a time.
@MainActor
protocol EditorPreviewLane: AnyObject {
    /// Renders `item` (at a browser's priority when `isUrgent`); false when the lane is gone (its
    /// helper exited or never started), true once the helper finished it, written or not.
    func render(_ item: EditorPreviewRenderItem, isUrgent: Bool) async -> Bool
    /// Ends the lane once its current preview is done.
    func close()
}

/// A lane that keeps one helper for every preview it renders: this app's executable with
/// `--render-editor-previews -` (`EditorPreviewRenderer.runStream`), in this process's isolated
/// state, fed one item at a time on its standard input. It starts at utility QoS and puts itself
/// in the background state for every preview but a browser's tiles (`isUrgent`). The helper exits
/// when its input closes, or with the app (`HelperRunCommand.exitWithParent`).
@MainActor
final class EditorPreviewHelperLane: EditorPreviewLane {
    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private var pending: CheckedContinuation<Bool, Never>?
    private var exited = false

    init?() {
        guard let process = HelperProcess.make([HelperRunCommand.editorPreviewArgument, EditorPreviewJob.streamArgument],
                                               qos: .utility) else { return nil }
        self.process = process
        process.standardInput = input
        process.standardOutput = output
        // A helper that exited makes a write fail instead of raising SIGPIPE here.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let lines = EditorPreviewDoneLines { [weak self] _ in
            Task { @MainActor in self?.finish(true) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData) }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.exited = true
                self.finish(false)
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            OWELog.error(.ui, "Editor previews: can't start a pre-warm helper: \(error)")
            return nil
        }
    }

    func render(_ item: EditorPreviewRenderItem, isUrgent: Bool) async -> Bool {
        guard !exited, pending == nil else { return false }
        let line: Data
        do {
            line = try EditorPreviewJob.streamLine(EditorPreviewJob.Item(subject: item.subject,
                                                                         outputBase: item.outputBase.path(percentEncoded: false),
                                                                         isUrgent: isUrgent))
        } catch {
            OWELog.error(.ui, "Editor previews: can't encode \(item.subject): \(error)")
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pending = continuation
                do {
                    try input.fileHandleForWriting.write(contentsOf: line)
                } catch {
                    finish(false)
                }
            }
        } onCancel: {
            Task { @MainActor in self.terminate() }
        }
    }

    func close() {
        // Optional: the helper may have closed its end already.
        try? input.fileHandleForWriting.close()
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func finish(_ rendered: Bool) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: rendered)
    }
}
