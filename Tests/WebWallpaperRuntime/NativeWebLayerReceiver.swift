import AppKit
import WebKit
@MainActor private final class Receiver: NSObject, NSWindowDelegate {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let window: NSWindow
    let viewport = NSView()
    let status = NSTextField(labelWithString: "Starting sandbox producer…")
    let report: URL
    var buffer = Data()
    var host: CALayer?
    var records = [[String: Any]]()

    init(project: String, producer: String, report: String) throws {
        self.report = URL(fileURLWithPath: report)
        window = NSWindow(contentRect: NSRect(x: 140, y: 160, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Glimmer Web 图层合成实验 — 独立接收进程"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = window.contentView!
        viewport.frame = NSRect(x: 0, y: 64, width: 1000, height: 656)
        viewport.autoresizingMask = [.width, .height]
        viewport.wantsLayer = true
        viewport.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(viewport)
        status.frame = NSRect(x: 16, y: 10, width: 580, height: 40)
        status.maximumNumberOfLines = 2
        content.addSubview(status)
        for (index, title) in ["暂停", "恢复", "采样", "结束"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(command(_:)))
            button.tag = index
            button.frame = NSRect(x: 600 + index * 96, y: 18, width: 84, height: 30)
            content.addSubview(button)
        }
        process.executableURL = URL(fileURLWithPath: producer)
        process.arguments = ["--web-layer-producer", project]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: self.report.deletingPathExtension().path + ".stderr") ?? FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        try process.run()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func command(_ button: NSButton) {
        let commands = ["pause", "resume", "metrics", "stop"]
        try? input.fileHandleForWriting.write(contentsOf: Data((commands[button.tag] + "\n").utf8))
    }
    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let range = buffer.range(of: Data([10])) {
            let line = Data(buffer[..<range.lowerBound]); buffer.removeSubrange(...range.lowerBound)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            records.append(object)
            if let json = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: report, options: .atomic)
            }
            let event = object["event"] as? String ?? "unknown"
            status.stringValue = "\(event) — 播放路径截图次数：0；接收进程 PID \(getpid())"
            if let contextID = object["contextID"] as? UInt32 {
                host = GWProbeLayerHost(contextID)
                if let host {
                    let width = CGFloat(object["width"] as? Double ?? 3024)/2
                    let height = CGFloat(object["height"] as? Double ?? 1964)/2
                    host.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    host.position = CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY)
                    let scale = min(viewport.bounds.width / width, viewport.bounds.height / height)
                    host.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                    viewport.layer?.addSublayer(host)
                    CATransaction.flush()
                }
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
    }
}


@main struct WebLayerReceiver {
    @MainActor private static var receiver: Receiver?
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            let file=Bundle.main.url(forResource:"Probe",withExtension:"json")!
            let config=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:String]
            receiver=try Receiver(project:config["project"]!, producer:config["producer"]!, report:config["report"]!)
            app.run()
        } catch { print(error);exit(1) }
    }
}
