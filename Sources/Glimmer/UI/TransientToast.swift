import AppKit
import SwiftUI

/// A short-lived, page-level message that floats above content without changing layout.
struct TransientToast: Identifiable, Equatable {
    enum Tone: Equatable {
        case info
        case success
        case warning
        case error

        var color: Color {
            switch self {
            case .info: .blue
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }

        var defaultSymbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.circle.fill"
            }
        }
    }

    let id: UUID
    let message: String
    let tone: Tone
    let symbol: String

    init(_ message: String, tone: Tone = .info, symbol: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.tone = tone
        self.symbol = symbol ?? tone.defaultSymbol
    }
}

private struct TransientToastModifier: ViewModifier {
    @Binding var toast: TransientToast?
    let duration: Duration

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    toastView(toast)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(100)
                        .task(id: toast.id) {
                            announce(toast.message)
                            do {
                                try await Task.sleep(for: duration)
                            } catch {
                                return
                            }
                            guard self.toast?.id == toast.id else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { self.toast = nil }
                        }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: toast?.id)
    }

    private func toastView(_ toast: TransientToast) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.tone.color)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { self.toast = nil }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .workshopGlassSurface(interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
        .accessibilityIdentifier("transient-toast")
    }

    @MainActor
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

extension View {
    func transientToast(_ toast: Binding<TransientToast?>, duration: Duration = .seconds(5)) -> some View {
        modifier(TransientToastModifier(toast: toast, duration: duration))
    }
}
