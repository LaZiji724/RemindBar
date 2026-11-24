import AppKit
import SwiftUI

/// The panel's input box: wraps, grows line by line with its text up to `maxLines` lines, and scrolls beyond that.
///
/// It is an `NSTextView` rather than SwiftUI's `TextField` because that is the one control every input method
/// (Apple's and third-party ones such as 豆包, 搜狗, 微信输入法) is written against: marked text, candidate window
/// placement and commit all go through its `NSTextInputClient` implementation.
/// Rules that keep input methods working:
///   • the model always holds exactly what the box shows, letters still being composed included, so a redraw of the
///     panel in the middle of a composition finds nothing to change and leaves the input method alone;
///   • only a real change from outside (cleared after adding, dictation) replaces the text, and drops a composition first;
///   • Return and Esc are only ours when the input method did not use them;
///   • no automatic substitutions (quotes, dashes, "1/2" → "½"), which would alter what the date parser reads.
struct GrowingTextInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Changes whenever the field should take the keyboard focus.
    var focusToken: Int
    var maxLines = 5
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputScrollView {
        let scroll = InputScrollView(maxLines: maxLines)
        let view = scroll.textView
        view.delegate = context.coordinator
        view.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        view.onMarkedTextChange = { [weak coordinator = context.coordinator, weak view] in
            if let coordinator, let view { coordinator.pushToModel(from: view) }
        }
        view.string = text
        view.setPlaceholder(placeholder)
        return scroll
    }

    func updateNSView(_ scroll: InputScrollView, context: Context) {
        let view = scroll.textView
        context.coordinator.parent = self
        view.setPlaceholder(placeholder)

        if view.string != text {
            // Changed from outside (cleared after adding, dictation, a suggestion…): the box must show it. A composition in
            // progress is dropped first, so the input method forgets its letters instead of writing them back.
            context.coordinator.applyingOutsideChange = true
            if view.hasMarkedText() {
                view.inputContext?.discardMarkedText()
                view.unmarkText()
            }
            view.replaceAll(with: text)
            context.coordinator.applyingOutsideChange = false
        }

        if focusToken != context.coordinator.focusToken {
            context.coordinator.focusToken = focusToken
            scroll.focusSoon()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: InputScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 220
        return CGSize(width: width, height: scroll.height(forWidth: width, text: text))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextInput
        var focusToken: Int
        /// True while the box is being changed to match a change that came from the model (not an edit by the person).
        var applyingOutsideChange = false

        init(_ parent: GrowingTextInput) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        func pushToModel(from view: NSTextView) {
            guard !applyingOutsideChange, parent.text != view.string else { return }
            parent.text = view.string
        }

        /// Every edit by the person (typing, paste, an input method committing text).
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            pushToModel(from: view)
        }
    }
}

// MARK: - AppKit pieces

/// Scroll view around the text view. Its height follows the text (one line … `maxLines` lines).
final class InputScrollView: NSScrollView {
    let textView: InputTextView
    private let maxLines: Int
    /// Height of one line of text; the box shows whole lines (1…`maxLines`), so no half line peeks out at its edge.
    static let lineHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)))
    /// Height of the round buttons beside the box. The space the box needs above and below to be as tall as these is
    /// `verticalPadding`, added by the layout around it (outside the part that scrolls).
    static let rowHeight: CGFloat = 28
    static let verticalPadding: CGFloat = max(4, (rowHeight - lineHeight) / 2)

    init(maxLines: Int) {
        self.maxLines = maxLines
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        textView = InputTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 28), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        documentView = textView
        // A permanent (legacy) scroller would take width from the text and change where lines wrap.
        NotificationCenter.default.addObserver(self, selector: #selector(preferredScrollerStyleChanged),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @objc private func preferredScrollerStyleChanged() { scrollerStyle = .overlay }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Height needed for this text at this width, measured on a scratch layout so the real one is not disturbed.
    func height(forWidth width: CGFloat, text: String) -> CGFloat {
        let font = textView.font ?? .systemFont(ofSize: 13)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width, 40), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let line = Self.lineHeight
        var used = layout.usedRect(for: container).height
        if layout.extraLineFragmentRect.height > 0 { used = max(used, layout.extraLineFragmentRect.maxY) }  // text ends with a line break
        let lines = min(max(ceil(used / line), 1), CGFloat(maxLines))
        return lines * line
    }

    /// Takes the keyboard focus once the view is in a window (the panel may not be on screen yet).
    func focusSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusSoon() }
    }
}

final class InputTextView: NSTextView {
    /// Return (nothing being composed, no modifier).
    var onSubmit: (() -> Void)?
    /// The input method changed the letters it is composing (AppKit does not report that as an edit).
    var onMarkedTextChange: (() -> Void)?
    private var placeholderText = ""
    /// Modifier keys of the key press being handled (read when it turns into a Return command).
    private var keyModifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        let font = NSFont.systemFont(ofSize: 13)
        self.font = font
        textColor = .textColor
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isEditable = true
        isSelectable = true

        // The text is read by the date parser: nothing may rewrite it behind the person's back.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        writingToolsBehavior = .none

        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }

    func setPlaceholder(_ text: String) {
        guard text != placeholderText else { return }
        placeholderText = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    /// Replaces the whole text from outside (not an edit by the person): no undo step, caret at the end.
    func replaceAll(with text: String) {
        string = text
        undoManager?.removeAllActions()
        let end = NSRange(location: (text as NSString).length, length: 0)
        setSelectedRange(end)
        needsDisplay = true
        // After the box has grown to the new text: bring the end (where the caret is) into view.
        DispatchQueue.main.async { [weak self] in self?.scrollRangeToVisible(end) }
    }

    // The hint shows while the box is empty and nothing is being composed.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholderText.isEmpty else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        NSAttributedString(string: placeholderText, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.88)   // the hint colour the box had before
        ]).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
        onMarkedTextChange?()
    }

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Still composing: the input method owns Return (it commits its letters), never submit from here.
            if hasMarkedText() { return }
            let modifiers = keyModifiers.isEmpty ? (NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []) : keyModifiers
            if modifiers.contains(.shift) || modifiers.contains(.option) || modifiers.contains(.control) {
                super.doCommand(by: selector)   // a real line break
            } else {
                onSubmit?()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc reaches here only when the input method did not use it (it was not composing): the panel folds away.
            NotificationCenter.default.post(name: .inputBoxDidCancel, object: self)
        default:
            super.doCommand(by: selector)
        }
    }
}

extension Notification.Name {
    /// Esc in the input box with nothing being composed.
    static let inputBoxDidCancel = Notification.Name("RemindBar.inputBoxDidCancel")
}
