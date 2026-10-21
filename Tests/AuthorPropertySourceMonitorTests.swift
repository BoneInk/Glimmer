import Foundation
import Darwin

@MainActor private final class EventCounter { var count = 0 }

@main struct AuthorPropertySourceMonitorTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let name = "gw-source-monitor-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures.append(name) } }
        func wait(_ predicate: @MainActor () -> Bool) async throws -> Bool {
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if predicate() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return predicate()
        }
        let file = root.appendingPathComponent("selected.png")
        try Data("first".utf8).write(to: file)
        let exact = EventCounter(), aliased = EventCounter()
        let exactMonitor = AuthorPropertySourceMonitor(urls: [file]) { exact.count += 1 }
        let aliasFile = URL(fileURLWithPath: "/tmp/\(name)/selected.png")
        let aliasMonitor = AuthorPropertySourceMonitor(urls: [aliasFile]) { aliased.count += 1 }
        try await Task.sleep(for: .seconds(1))
        var baseline = exact.count
        let aliasBaseline = aliased.count
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" modified".utf8)); try handle.close()
        check(try await wait { exact.count > baseline }, "selected file modification emits native event")
        check(try await wait { aliased.count > aliasBaseline }, "system path alias receives canonical FSEvents paths")
        baseline = exact.count
        let renamed = root.appendingPathComponent("renamed.png")
        try fm.moveItem(at: file, to: renamed)
        check(try await wait { exact.count > baseline }, "selected file rename emits native event")
        exactMonitor.dispose(); aliasMonitor.dispose()
        let stoppedExact = exact.count, stoppedAlias = aliased.count
        try Data("after dispose".utf8).write(to: file)
        try await Task.sleep(for: .seconds(1))
        check(exact.count == stoppedExact && aliased.count == stoppedAlias, "dispose suppresses pending and future callbacks")
        exactMonitor.dispose()
        check(exact.count == stoppedExact, "dispose is idempotent")

        let replacements = root.appendingPathComponent("replace.png")
        try Data("before".utf8).write(to: replacements)
        let replacementEvents = EventCounter()
        let replacementMonitor = AuthorPropertySourceMonitor(urls: [replacements]) { replacementEvents.count += 1 }
        check(replacementMonitor.isActive, "file descriptor observation reports active")
        baseline = replacementEvents.count
        try Data("atomic replacement".utf8).write(to: replacements, options: .atomic)
        check(try await wait { replacementEvents.count > baseline }, "atomic file replacement invalidates selected inode")
        try await Task.sleep(for: .milliseconds(500))
        baseline = replacementEvents.count
        let replacementHandle = try FileHandle(forWritingTo: replacements)
        try replacementHandle.seekToEnd(); try replacementHandle.write(contentsOf: Data(" again".utf8)); try replacementHandle.close()
        check(try await wait { replacementEvents.count > baseline }, "same selected path is rearmed after atomic replacement")
        baseline = replacementEvents.count
        try fm.removeItem(at: replacements)
        check(try await wait { replacementEvents.count > baseline }, "selected file deletion emits event")
        replacementMonitor.dispose()
        check(!replacementMonitor.isActive, "disposed file observation reports inactive")

        let restricted = root.appendingPathComponent("traverse-only", isDirectory: true)
        try fm.createDirectory(at: restricted, withIntermediateDirectories: true)
        let restrictedFile = restricted.appendingPathComponent("selected.png")
        try Data("allowed file".utf8).write(to: restrictedFile)
        try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: restricted.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let restrictedEvents = EventCounter()
        let restrictedMonitor = AuthorPropertySourceMonitor(urls: [restrictedFile]) { restrictedEvents.count += 1 }
        check(restrictedMonitor.isActive, "file observation requires no parent-directory read permission")
        let restrictedHandle = try FileHandle(forWritingTo: restrictedFile)
        try restrictedHandle.write(contentsOf: Data("updated".utf8)); try restrictedHandle.close()
        check(try await wait { restrictedEvents.count > 0 }, "file changes observed with traverse-only parent")
        restrictedMonitor.dispose()
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)

        // A directory grant authorizes this subtree, never reading its parent.
        // WatchRoot previously opened ancestors during FSEventStreamCreate.
        let directoryParent = root.appendingPathComponent("directory-traverse-only", isDirectory: true)
        let selectedDirectory = directoryParent.appendingPathComponent("selected", isDirectory: true)
        try fm.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: directoryParent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryParent.path) }
        let deniedParentFD = open(directoryParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let deniedParentError = errno
        if deniedParentFD >= 0 { close(deniedParentFD) }
        check(deniedParentFD < 0 && deniedParentError == EACCES, "POSIX independently refuses reading selected directory parent")
        let restrictedTreeEvents = EventCounter()
        let restrictedTreeMonitor = AuthorPropertySourceMonitor(urls: [selectedDirectory]) { restrictedTreeEvents.count += 1 }
        check(restrictedTreeMonitor.isActive, "recursive directory observation starts with traverse-only parent")
        try await Task.sleep(for: .milliseconds(700))
        baseline = restrictedTreeEvents.count
        let permittedChild = selectedDirectory.appendingPathComponent("child.txt")
        try Data("allowed subtree".utf8).write(to: permittedChild)
        check(try await wait { restrictedTreeEvents.count > baseline }, "recursive addition requires no parent-directory read permission")
        baseline = restrictedTreeEvents.count
        try fm.removeItem(at: permittedChild)
        check(try await wait { restrictedTreeEvents.count > baseline }, "recursive removal works with traverse-only parent")
        restrictedTreeMonitor.dispose()
        check(!restrictedTreeMonitor.isActive, "disposed recursive monitor reports inactive")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryParent.path)

        let fileDeinitEvents = EventCounter()
        var fileDeinitMonitor: AuthorPropertySourceMonitor? = AuthorPropertySourceMonitor(urls: [file]) { fileDeinitEvents.count += 1 }
        check(fileDeinitMonitor?.isActive == true, "file deinit fixture owns active source")
        fileDeinitMonitor = nil
        let stoppedFileDeinit = fileDeinitEvents.count
        let deinitHandle = try FileHandle(forWritingTo: file)
        try deinitHandle.write(contentsOf: Data("late file update".utf8)); try deinitHandle.close()
        try await Task.sleep(for: .milliseconds(500))
        check(fileDeinitEvents.count == stoppedFileDeinit, "file source deinit suppresses subsequent events")

        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let treeEvents = EventCounter()
        var treeMonitor: AuthorPropertySourceMonitor? = AuthorPropertySourceMonitor(urls: [directory]) { treeEvents.count += 1 }
        check(treeMonitor?.isActive == true, "directory root vnode and recursive stream are active")
        let directoryAliasEvents = EventCounter()
        let directoryAlias = URL(fileURLWithPath: "/tmp/\(name)/directory", isDirectory: true)
        let directoryAliasMonitor = AuthorPropertySourceMonitor(urls: [directoryAlias]) { directoryAliasEvents.count += 1 }
        try await Task.sleep(for: .seconds(1))
        baseline = treeEvents.count
        let directoryAliasBaseline = directoryAliasEvents.count
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = nested.appendingPathComponent("new.png")
        try Data("new".utf8).write(to: child)
        check(try await wait { treeEvents.count > baseline }, "recursive directory addition emits native event")
        check(try await wait { directoryAliasEvents.count > directoryAliasBaseline }, "directory system alias receives recursive events")
        baseline = treeEvents.count
        try Data("changed".utf8).write(to: child)
        check(try await wait { treeEvents.count > baseline }, "nested content update emits native event")
        baseline = treeEvents.count
        try fm.removeItem(at: child)
        check(try await wait { treeEvents.count > baseline }, "recursive directory removal emits native event")
        baseline = treeEvents.count
        let moved = root.appendingPathComponent("moved-directory", isDirectory: true)
        try fm.moveItem(at: directory, to: moved)
        check(try await wait { treeEvents.count > baseline }, "selected directory root rename emits event")
        directoryAliasMonitor.dispose()
        treeMonitor?.dispose(); treeMonitor = nil
        let stoppedTree = treeEvents.count
        try Data("late".utf8).write(to: moved.appendingPathComponent("late.png"))
        try await Task.sleep(for: .seconds(1))
        check(treeEvents.count == stoppedTree, "disposed stream releases without callback after owner destruction")
        let deinitEvents = EventCounter()
        var deinitMonitor: AuthorPropertySourceMonitor? = AuthorPropertySourceMonitor(urls: [moved]) { deinitEvents.count += 1 }
        try await Task.sleep(for: .seconds(1))
        check(deinitMonitor != nil, "deinit fixture owns active stream")
        deinitMonitor = nil
        let stoppedDeinit = deinitEvents.count
        try Data("after deinit".utf8).write(to: moved.appendingPathComponent("late.png"))
        try await Task.sleep(for: .seconds(1))
        check(deinitEvents.count == stoppedDeinit, "deinit invalidates native stream and suppresses callbacks")
        let deletedRoot = root.appendingPathComponent("delete-selected-directory", isDirectory: true)
        try fm.createDirectory(at: deletedRoot, withIntermediateDirectories: true)
        let rootDeleteEvents = EventCounter()
        let rootDeleteMonitor = AuthorPropertySourceMonitor(urls: [deletedRoot]) { rootDeleteEvents.count += 1 }
        try await Task.sleep(for: .milliseconds(700))
        baseline = rootDeleteEvents.count
        try fm.removeItem(at: deletedRoot)
        check(try await wait { rootDeleteEvents.count > baseline }, "selected directory root deletion emits vnode event without WatchRoot")
        rootDeleteMonitor.dispose()
        let stoppedRootDelete = rootDeleteEvents.count
        try fm.createDirectory(at: deletedRoot, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(700))
        check(rootDeleteEvents.count == stoppedRootDelete, "disposed root vnode source suppresses replacement events")
        print("AuthorPropertySourceMonitorTests: \(checks - failures.count)/\(checks) passed")
        if !failures.isEmpty { throw NSError(domain: "AuthorPropertySourceMonitorTests", code: failures.count, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
