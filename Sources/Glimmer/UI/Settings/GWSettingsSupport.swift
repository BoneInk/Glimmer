import AppKit
import SwiftUI

// F17/F18/F20 设置模块界面共用辅助。

/// 键值信息行（设置页展示用）。
struct GWSettingsKeyValueRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.callout)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(title)：\(value)，\($0)" } ?? "\(title)：\(value)")
    }
}

/// 提示文本行的统一样式。
struct GWSettingsFootnote: View {
    let text: String
    var isError: Bool = false

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
        }
        .font(.caption2)
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension GWSettingsFormat {
    /// 文件名用的时间戳（不包含用户信息）。
    static func fileStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}
