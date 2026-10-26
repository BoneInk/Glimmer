import AppKit
import ApplicationServices

@MainActor
protocol GWWindowEventMonitoring: AnyObject {
    /// true 表示应用/桌面可见性转换，需在系统动画结束后再核对一次。
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    var onIssue: (@MainActor (String?) -> Void)? { get set }
    func synchronize(applicationPIDs: Set<pid_t>, refreshWindows: Bool)
    func stop()
}

/// 只订阅窗口事件；没有计时轮询。所有跨进程 AX 请求都在 utility 队列执行。
@MainActor
final class GWAccessibilityWindowMonitor: GWWindowEventMonitoring {
    var onChange: (@MainActor (Bool) -> Void)?
    var onIssue: (@MainActor (String?) -> Void)?
    private var worker: Worker?
    private var generation = UUID()

    func synchronize(applicationPIDs: Set<pid_t>, refreshWindows: Bool) {
        if worker == nil {
            let token = UUID()
            generation = token
            worker = Worker { [weak self] unsupported, denied, requiresSettling in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.onIssue?(denied ? "辅助功能权限不可用，请重新授权。" :
                        (unsupported ? "部分应用未提供窗口事件，相关窗口变化可能无法自动检测。" : nil))
                    self.onChange?(requiresSettling)
                }
            }
        }
        worker?.synchronize(applicationPIDs, refreshWindows: refreshWindows)
    }

    func stop() {
        generation = UUID()
        worker?.stop()
        worker = nil
    }

    isolated deinit { worker?.stop() }

    /// AX 对象和记录只在 queue 上访问。主运行循环只负责接收并转发通知。
    private final class Worker: @unchecked Sendable {
        private struct Registration {
            let element: AXUIElement
            var notifications: [String]
        }
        private struct Record {
            let observer: AXObserver
            let application: AXUIElement
            let context: UnsafeMutableRawPointer
            var applicationNotifications: [String]
            var windows: [Registration] = []
            var unavailable = false
        }
        private let queue = DispatchQueue(label: "com.boneinkzhong.glimmer.window-events", qos: .utility)
        private let report: @Sendable (Bool, Bool, Bool) -> Void
        private var records: [pid_t: Record] = [:]
        private var failedPIDs: Set<pid_t> = []
        private var stopped = false
        private var permissionDenied = false

        init(report: @escaping @Sendable (Bool, Bool, Bool) -> Void) { self.report = report }

        func synchronize(_ pids: Set<pid_t>, refreshWindows: Bool) {
            queue.async { [self] in
                guard !stopped else { return }
                failedPIDs.formIntersection(pids)
                for pid in Set(records.keys).subtracting(pids) { remove(pid) }
                for pid in pids {
                    if records[pid] == nil { install(pid) }
                    else if refreshWindows { updateWindows(pid) }
                }
                emit(requiresSettling: true)
            }
        }

        func stop() {
            queue.async { [self] in
                stopped = true
                for pid in Array(records.keys) { remove(pid) }
            }
        }

        private func install(_ pid: pid_t) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { observer, element, notification, context in
                guard let context else { return }
                let worker = Unmanaged<Worker>.fromOpaque(context).takeUnretainedValue()
                // callback 中不发起跨进程消息；使用 observer 的身份在后台查找所属进程。
                let event = Event(observer: observer, notification: notification as String)
                worker.queue.async { [worker, event] in worker.receive(event) }
            }, &observer)
            guard result == .success, let observer else {
                failedPIDs.insert(pid)
                if result == .apiDisabled { permissionDenied = true }
                return
            }
            failedPIDs.remove(pid)

            // 每个 source 持有一个 context 引用，移除 source 后在主队列释放，避免回调悬空。
            let context = Unmanaged.passRetained(self).toOpaque()
            var record = Record(observer: observer, application: application, context: context,
                                applicationNotifications: [])
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                         kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
                         kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                let error = AXObserverAddNotification(observer, application, name as CFString, context)
                if error == .success { record.applicationNotifications.append(name) }
                if error == .apiDisabled { permissionDenied = true; break }
                if error == .cannotComplete { record.unavailable = true; break }
            }
            records[pid] = record
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if !permissionDenied && !record.unavailable { updateWindows(pid) }
        }

        private struct Event: @unchecked Sendable {
            let observer: AXObserver
            let notification: String
        }

        private func receive(_ event: Event) {
            guard !stopped, let pid = records.first(where: { CFEqual($0.value.observer, event.observer) })?.key else { return }
            if [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                kAXUIElementDestroyedNotification].contains(event.notification) {
                updateWindows(pid)
            }
            let geometryEvents = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                  kAXMovedNotification, kAXResizedNotification]
            emit(requiresSettling: !geometryEvents.contains(event.notification))
        }

        private func updateWindows(_ pid: pid_t) {
            guard var record = records[pid] else { return }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(record.application, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let windows = value as? [AXUIElement] else {
                if error == .apiDisabled { permissionDenied = true }
                record.unavailable = true
                records[pid] = record
                return
            }
            record.unavailable = false
            let removed = record.windows.filter { old in !windows.contains { CFEqual($0, old.element) } }
            for old in removed {
                for name in old.notifications {
                    AXObserverRemoveNotification(record.observer, old.element, name as CFString)
                }
            }
            record.windows.removeAll { old in !windows.contains { CFEqual($0, old.element) } }
            for window in windows where !record.windows.contains(where: { CFEqual($0.element, window) }) {
                AXUIElementSetMessagingTimeout(window, 0.15)
                var registration = Registration(element: window, notifications: [])
                for name in [kAXWindowMovedNotification, kAXWindowResizedNotification,
                             kAXMovedNotification, kAXResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                             kAXUIElementDestroyedNotification] {
                    let result = AXObserverAddNotification(record.observer, window, name as CFString, record.context)
                    if result == .success { registration.notifications.append(name) }
                    if result == .apiDisabled { permissionDenied = true; break }
                    if result == .cannotComplete { record.unavailable = true; break }
                }
                record.windows.append(registration)
                if permissionDenied || record.unavailable { break }
            }
            let geometryEvents: Set<String> = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                              kAXMovedNotification, kAXResizedNotification]
            if record.windows.contains(where: { Set($0.notifications).isDisjoint(with: geometryEvents) }) {
                record.unavailable = true
            }
            records[pid] = record
        }

        private func emit(requiresSettling: Bool) {
            report(!failedPIDs.isEmpty || records.values.contains(where: \.unavailable), permissionDenied, requiresSettling)
        }

        private func remove(_ pid: pid_t) {
            guard let record = records.removeValue(forKey: pid) else { return }
            let source = AXObserverGetRunLoopSource(record.observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            // source 已移除，无需逐个向可能无响应或已退出的进程发送取消订阅请求。
            let context = record.context
            let release = ContextRelease(context: context)
            DispatchQueue.main.async { release.perform() }
        }

        private struct ContextRelease: @unchecked Sendable {
            let context: UnsafeMutableRawPointer
            func perform() { Unmanaged<Worker>.fromOpaque(context).release() }
        }
    }
}
