import AppKit
import SwiftUI

/// A native search field for a window toolbar, placed as an ordinary toolbar item. `.searchable`
/// pins its field to the trailing edge of the toolbar on macOS; this one sits where its item is
/// declared, so a tab can put search first.
///
/// The text is bound as it is typed; Return calls `onSubmit`; Escape and the field's clear button
/// empty it. Edit › Find focuses it (`MenuActions.focusSearch`, through `identifier`).
struct ToolbarSearchField: NSViewRepresentable {
    /// Marks the field so Edit › Find can find it in the window.
    static let identifier = NSUserInterfaceItemIdentifier("app.openwallpaperengine.toolbarSearch")
    /// `NSSearchToolbarItem`'s default field width, the width `.searchable` gave the field.
    static let width: CGFloat = 240

    @Binding var text: String
    let prompt: LocalizedStringResource
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.identifier = Self.identifier
        field.placeholderString = String(localized: prompt)
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.sync(_:))
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(parent: ToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// The field's action: Return, or the clear button, which empties it first.
        @objc func sync(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit?()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = ""
                parent.text = ""
                return true
            default:
                return false
            }
        }
    }
}

extension ToolbarSearchField {
    /// The field as a toolbar item, at the width `.searchable` gave it.
    @ToolbarContentBuilder static func item(text: Binding<String>, prompt: LocalizedStringResource,
                                             onSubmit: (() -> Void)? = nil) -> some ToolbarContent {
        ToolbarItem {
            ToolbarSearchField(text: text, prompt: prompt, onSubmit: onSubmit)
                .frame(minWidth: 140, idealWidth: width, maxWidth: width)
                .help(Text(prompt))
        }
    }
}
