//
//  SafeRestartNotice.swift
//  Open Wallpaper Engine
//

import Cocoa
import SwiftUI

/// A small floating panel with a message, Dismiss and an optional Retry. It does not
/// take focus or block anything, unlike an alert.
@MainActor
final class SafeRestartNotice {
    private let panel: NSPanel

    init(message: String, onRetry: (() -> Void)?, onDismiss: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let notice = NoticeView(message: message, onRetry: onRetry, onDismiss: onDismiss).appAccentTint()
        let hosting: NSView
        if #available(macOS 26, *) {
            hosting = NSHostingView(rootView: notice)
        } else {
            // Before glass: a frosted panel the desktop shows through.
            hosting = NSHostingView(rootView: notice.frostedWindowBackground(.hudWindow))
        }
        if #available(macOS 26, *) {
            // The panel itself is the glass: a clear window whose content is one glass view.
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.contentView = hosting
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentView = glass
        } else {
            panel.contentView = hosting
            panel.isOpaque = false
            panel.backgroundColor = .clear
        }
        panel.setContentSize(hosting.fittingSize)
    }

    func show() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private struct NoticeView: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                // Not glass buttons: the panel is already glass on macOS 26.
                Button("Dismiss", action: onDismiss)
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
