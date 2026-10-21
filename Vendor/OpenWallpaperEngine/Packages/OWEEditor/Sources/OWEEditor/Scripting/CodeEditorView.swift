import AppKit
import SwiftUI
import OWESceneEditing

/// The script and shader editors' text: JavaScript or WE shader highlighting
/// (`CodeEditorLanguage`), line numbers with error marks, the find bar (⌘F), autocomplete
/// (SceneScript's API after a `.`, a shader's words; ⌥⎋ / F5 anywhere), automatic indentation,
/// commenting lines (⌘/, ⌥⌘/), and an undo history of its own (the window's undo is the scene's edits).
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var diagnostics: [SceneScriptDiagnostic]
    var catalog: SceneScriptAPICatalog
    /// The panel's menus edit the text through it (Snippets, Format Document, Comment Selection).
    var controller: CodeEditorController?
    /// A script, or a shader in the shader editor (`CodeEditorLanguage`).
    var language: CodeEditorLanguage = .sceneScript
    /// ⌘↩: apply the script.
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ScriptTextView()
        textView.catalog = catalog
        textView.language = language
        textView.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.onCommit() }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = CodeEditorStyle.font
        textView.typingAttributes = CodeEditorStyle.baseAttributes
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(language.accessibilityLabel)
        textView.string = text

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        controller?.textView = textView
        context.coordinator.highlight()
        context.coordinator.show(diagnostics)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        controller?.textView = textView
        if textView.string != text {
            // A template or an undo of the scene replaced the text: keep it one undoable change.
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: range, replacementString: text) {
                textView.replaceCharacters(in: range, with: text)
                textView.didChangeText()
            }
            context.coordinator.highlight()
        }
        context.coordinator.show(diagnostics)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: ScriptTextView?
        weak var ruler: LineNumberRulerView?
        /// The editor's own history: typing is undone here, not in the scene's undo.
        let undoManager = UndoManager()
        private var shown: [SceneScriptDiagnostic] = []

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            highlight()
            if parent.text != textView.string { parent.text = textView.string }
            ruler?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let result = parent.language.completions(in: textView.string, at: NSMaxRange(charRange), catalog: parent.catalog)
            index?.pointee = result.items.isEmpty ? -1 : 0
            return result.items.map(\.label)
        }

        /// Colours the whole text from its tokens (scripts are short; this is a few hundred µs).
        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(CodeEditorStyle.baseAttributes, range: full)
            for (range, color) in parent.language.colors(in: storage.string) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
            textView.typingAttributes = CodeEditorStyle.baseAttributes
            applyDiagnosticMarks()
        }

        func show(_ diagnostics: [SceneScriptDiagnostic]) {
            guard diagnostics != shown else { return }
            shown = diagnostics
            ruler?.diagnostics = diagnostics
            applyDiagnosticMarks()
        }

        /// A tinted background under each line with an error.
        private func applyDiagnosticMarks() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let text = textView.string as NSString
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
            for diagnostic in shown {
                guard let line = diagnostic.line, let range = Self.range(ofLine: line, in: text) else { continue }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: CodeEditorStyle.errorLine, forCharacterRange: range)
            }
        }

        static func range(ofLine line: Int, in text: NSString) -> NSRange? {
            var current = 1
            var location = 0
            while current < line {
                let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
                guard next.location != NSNotFound else { return nil }
                location = NSMaxRange(next)
                current += 1
            }
            return text.lineRange(for: NSRange(location: location, length: 0))
        }
    }
}

/// The panel's handle on the code editor's text: its menus' edits go through the text view, so
/// they are steps of the editor's own undo and keep the selection where it belongs.
@MainActor
final class CodeEditorController {
    weak var textView: ScriptTextView?

    /// Replaces the text and selection with `edit`'s result, one undoable change.
    func edit(_ edit: (String, NSRange) -> (text: String, selection: NSRange)) {
        guard let textView else { return }
        let result = edit(textView.string, textView.selectedRange())
        replace(with: result.text, selecting: result.selection)
    }

    /// Replaces the whole text (a snippet, Format Document), the caret where it was or at the end.
    func replaceText(_ edit: (String) -> String) {
        guard let textView else { return }
        let caret = textView.selectedRange().location
        let text = edit(textView.string)
        replace(with: text, selecting: NSRange(location: min(caret, (text as NSString).length), length: 0))
    }

    private func replace(with text: String, selecting selection: NSRange) {
        guard let textView, textView.string != text || textView.selectedRange() != selection else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.string != text, textView.shouldChangeText(in: range, replacementString: text) {
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        textView.window?.makeFirstResponder(textView)
    }

    func formatDocument() { replaceText(SceneScriptSourceEdits.formatted) }
    func commentSelection() { edit(SceneScriptSourceEdits.commenting) }
    func uncommentSelection() { edit(SceneScriptSourceEdits.uncommenting) }
}

/// Fonts and colours of the code editor, following the system's appearance.
enum CodeEditorStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    static let errorLine = NSColor.systemRed.withAlphaComponent(0.16)

    static func color(_ kind: JavaScriptToken.Kind) -> NSColor? {
        switch kind {
        case .keyword: return .systemPink
        case .string, .template: return .systemRed
        case .regex: return .systemOrange
        case .number: return .systemPurple
        case .lineComment, .blockComment: return .systemGray
        case .api: return .systemTeal
        case .identifier, .punctuation: return nil
        }
    }
}

/// The text view of the code editor: completion of SceneScript's API and keyboard behaviour that
/// suits code.
final class ScriptTextView: NSTextView {
    var catalog = SceneScriptAPICatalog.standard
    var language = CodeEditorLanguage.sceneScript
    var onCommit: (@MainActor () -> Void)?

    /// The word completion replaces: the identifier before the cursor (empty after a `.`).
    override var rangeForUserCompletion: NSRange {
        let selection = selectedRange()
        guard selection.length == 0 else { return super.rangeForUserCompletion }
        return language.completions(in: string, at: selection.location, catalog: catalog).range
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        // A member access: offer the members.
        if (string as? String) == ".", language.completesAfterDot {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder === self else { return }
                if !self.language.completions(in: self.string, at: self.selectedRange().location, catalog: self.catalog).items.isEmpty {
                    self.complete(nil)
                }
            }
        }
    }

    /// A new line keeps the current line's indentation, one level more after `{`.
    override func insertNewline(_ sender: Any?) {
        let text: NSString = string as NSString
        let selection: NSRange = selectedRange()
        let lineRange: NSRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineLength: Int = selection.location - lineRange.location
        let line: String = text.substring(with: NSRange(location: lineRange.location, length: lineLength))
        var indentation = String(line.prefix { (character: Character) -> Bool in character == " " || character == "\t" })
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("{") { indentation += "\t" }
        super.insertNewline(sender)
        if !indentation.isEmpty { insertText(indentation, replacementRange: selectedRange()) }
    }

    /// ⌘↩ applies the script; ⌘F, ⌘G and ⇧⌘G search it, also where the app's menu has no Find.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "\r" {
            onCommit?()
            return true
        }
        // ⌘/ comments the selected lines, ⌥⌘/ uncomments them (WE's Ctrl+K C and Ctrl+K U).
        if key == "/", flags == .command || flags == [.command, .option] {
            let edit = flags == .command ? SceneScriptSourceEdits.commenting : SceneScriptSourceEdits.uncommenting
            let result = edit(string, selectedRange())
            let range = NSRange(location: 0, length: (string as NSString).length)
            if shouldChangeText(in: range, replacementString: result.text) {
                replaceCharacters(in: range, with: result.text)
                didChangeText()
                setSelectedRange(result.selection)
            }
            return true
        }
        let action: NSTextFinder.Action?
        switch (flags, key) {
        case (.command, "f"): action = .showFindInterface
        case (.command, "g"): action = .nextMatch
        case ([.command, .shift], "g"): action = .previousMatch
        default: action = nil
        }
        if let action {
            showFinder(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func showFinder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performFindPanelAction(item)
    }
}

/// Line numbers beside the code, with a mark on each line that has an error (its message as the
/// tooltip).
final class LineNumberRulerView: NSRulerView {
    var diagnostics: [SceneScriptDiagnostic] = [] {
        didSet {
            needsDisplay = true
            toolTip = diagnostics.isEmpty ? nil : diagnostics.map { diagnostic in
                diagnostic.line.map { "\($0): \(diagnostic.message)" } ?? diagnostic.message
            }.joined(separator: "\n")
        }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentChanged() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let errorLines = Set(diagnostics.compactMap(\.line))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let inset = textView.textContainerInset.height
        let convert = convert(NSPoint.zero, from: textView)

        // The line number of the first visible character.
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if characters.location > 0, text.character(at: characters.location - 1) != 0x0A { line -= 1 }

        var location = characters.location
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: min(lineRange.location, max(0, text.length - 1)))
            var fragment = text.length == 0 ? NSRect(x: 0, y: 0, width: 0, height: font.pointSize + 4)
                : layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            fragment.origin.y += inset + convert.y
            let isError = errorLines.contains(line)
            if isError {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: fragment.midY - 3.5, width: 7, height: 7)).fill()
            }
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isError ? NSColor.systemRed : NSColor.secondaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: fragment.midY - size.height / 2),
                       withAttributes: attributes)
            line += 1
            location = NSMaxRange(lineRange)
        } while location < NSMaxRange(characters) && location < text.length
        // A trailing empty line.
        if text.length > 0, text.character(at: text.length - 1) == 0x0A, NSMaxRange(characters) >= text.length {
            var fragment = layoutManager.extraLineFragmentRect
            fragment.origin.y += inset + convert.y
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: fragment.midY - size.height / 2),
                       withAttributes: attributes)
        }
    }

    /// A click selects the line.
    override func mouseDown(with event: NSEvent) {
        guard let textView = clientView as? NSTextView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: NSPoint(x: 0, y: point.y))
        let text = textView.string as NSString
        guard index <= text.length else { return }
        textView.setSelectedRange(text.lineRange(for: NSRange(location: index, length: 0)))
        textView.window?.makeFirstResponder(textView)
    }
}
