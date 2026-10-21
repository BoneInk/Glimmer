import Foundation

/// Derived afresh from the coordinator's item; validation must never reuse download progress.
struct WorkshopDownloadProgressPresentation: Equatable {
    enum Ring: Equatable {
        case none, waiting, determinate(Double), indeterminate
    }

    let ring: Ring
    let symbolName: String
    let statusText: String?
    let accessibilityValue: String
    let downloadDisabled: Bool

    init(item: WorkshopDownloadItem?) {
        guard let item else {
            ring = .none
            symbolName = "arrow.down"
            statusText = nil
            accessibilityValue = "加入下载队列"
            downloadDisabled = false
            return
        }
        switch item.state {
        case .downloading, .paused: downloadDisabled = false
        default: downloadDisabled = !item.state.isTerminal || item.state.isSuccess
        }
        switch item.state {
        case .pausing:
            ring = .indeterminate
            symbolName = "pause"
            statusText = "正在暂停"
            accessibilityValue = "正在暂停，保留已有数据"
        case .paused:
            if let value = item.progressFraction, value.isFinite { ring = .determinate(min(max(value, 0), 1)) }
            else { ring = .none }
            symbolName = "play.fill"
            statusText = "已暂停"
            accessibilityValue = "已暂停，继续下载并校验已有数据"
        case .queued:
            ring = .waiting
            symbolName = "clock"
            statusText = "排队中"
            accessibilityValue = "排队中"
        case .downloading(let fraction, let text):
            var value: String
            // State is authoritative. A nil fraction means the service has no measured progress.
            if let fraction, fraction.isFinite {
                let progress = min(max(fraction, 0), 1)
                ring = .determinate(progress)
                let percent = String(format: "%.0f%%", progress * 100)
                statusText = "下载中 \(percent)"
                value = "下载中，\(percent)"
            } else {
                ring = .indeterminate
                statusText = "下载中"
                value = "下载中，进度未知"
            }
            accessibilityValue = text.isEmpty ? value : value + "，" + text
            symbolName = "pause"
        case .validating:
            ring = .indeterminate
            symbolName = "checkmark.shield"
            statusText = "正在校验"
            accessibilityValue = "正在校验，进度未知"
        case .completed:
            ring = .none
            symbolName = "checkmark"
            statusText = "已下载"
            accessibilityValue = "已下载并校验完成"
        case .failed:
            ring = .none
            symbolName = "arrow.clockwise"
            statusText = "下载失败"
            accessibilityValue = "下载失败，重新加入下载队列"
        case .cancelled:
            ring = .none
            symbolName = "arrow.down"
            statusText = "已取消"
            accessibilityValue = "已取消，重新加入下载队列"
        }
    }

    var actionTitle: String {
        if symbolName == "pause", !downloadDisabled { return "暂停下载" }
        if symbolName == "play.fill" { return "继续下载" }
        if symbolName == "arrow.clockwise" { return "重试下载" }
        return "下载壁纸"
    }
}
