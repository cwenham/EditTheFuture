#if os(macOS)
import AppKit
import SwiftUI
import FutureFormula

/// The formula editor (docs/UI.md, 5.7): an AppKit text view with line numbers, colouring,
/// underlined mistakes and a completion list that follows the caret.
struct FormulaEditor: View {
    let text: String
    /// The text `diagnoses` were worked out for. They're only drawn while it's still the text.
    let diagnosedText: String?
    let diagnoses: [FormulaDiagnosis]
    let completions: (String, Int) -> (range: NSRange, items: [FormulaCompletion])
    let insertRequest: FormulaInsertRequest?
    var onChange: (String) -> Void
    var onApply: () -> Void

    @State private var completion = FormulaCompletionState()

    var body: some View {
        GeometryReader { geometry in
            FormulaTextArea(text: text, diagnosedText: diagnosedText, diagnoses: diagnoses, completions: completions,
                            insertRequest: insertRequest, completion: completion, onChange: onChange, onApply: onApply)
                .overlay(alignment: .topLeading) {
                    if completion.isVisible {
                        CompletionList(state: completion)
                            .offset(x: min(completion.anchor.x, max(0, geometry.size.width - CompletionList.width - 4)),
                                    y: completion.anchor.y + 2)
                    }
                }
        }
        .background(FormulaColors.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formula")
    }
}

/// Text the insert palette asks to put at the caret. A new `id` asks again.
struct FormulaInsertRequest: Equatable {
    let id: Int
    let text: String
    /// How far back from the end of `text` the caret goes: 1 puts it inside "min()".
    let caretBack: Int
}

/// The completion list's contents and where it sits, shared by the text view and the list.
@MainActor
@Observable
final class FormulaCompletionState {
    var items: [FormulaCompletion] = []
    var selected = 0
    /// The text a choice replaces.
    var range = NSRange(location: 0, length: 0)
    /// Just under the caret, in the editor's coordinates (top left is 0, 0).
    var anchor = CGPoint.zero
    /// Set by the text view: puts a choice in.
    @ObservationIgnored var accept: (FormulaCompletion) -> Void = { _ in }

    var isVisible: Bool { !items.isEmpty }

    func dismiss() {
        if !items.isEmpty { items = [] }
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + by + items.count) % items.count
    }
}

enum FormulaColors {
    static let background = Color(hex: "#111317")
    static let plain = NSColor(hex: "#ECEEF1")
    static let lineNumber = NSColor(hex: "#848B95")
    static let error = NSColor(hex: "#FF6B6B")
    static let errorText = NSColor(hex: "#FF9C9C")
    static let warning = NSColor(hex: "#FFC77A")

    static func color(_ kind: FormulaTokenKind) -> NSColor {
        switch kind {
        case .keyword: return NSColor(hex: "#C3A6FF")
        case .number: return NSColor(hex: "#FFC77A")
        case .string: return NSColor(hex: "#9FE3C4")
        case .comment: return NSColor(hex: "#848B95")
        case .builtin: return NSColor(hex: "#46C8E0")
        case .function: return NSColor(hex: "#ECEEF1")
        case .reference, .eventField: return NSColor(hex: "#8CC4FF")
        case .lag: return NSColor(hex: "#4FD1A5")
        case .name: return plain
        case .symbol: return NSColor(hex: "#A3A9B1")
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The completion list under the caret.
private struct CompletionList: View {
    let state: FormulaCompletionState
    static let width: CGFloat = 300
    static let rows = 8

    var body: some View {
        let items = state.items
        let first = max(0, min(state.selected - Self.rows / 2, items.count - Self.rows))
        let shown = Array(items.enumerated().dropFirst(first).prefix(Self.rows))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.element.id) { offset, item in
                let selected = offset == state.selected
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(selected ? Theme.text : Color(nsColor: color(item.kind)))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(selected ? Theme.proposal.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { state.accept(item) }
            }
            if items.count > Self.rows {
                Text("\(items.count) choices · ↑↓ to move")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            }
        }
        .padding(4)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(hex: "#1F2228"), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private func color(_ kind: FormulaCompletion.Kind) -> NSColor {
        switch kind {
        case .function: return FormulaColors.color(.function)
        case .builtin: return FormulaColors.color(.builtin)
        case .slot, .slotValue, .slotEvent, .eventField: return FormulaColors.color(.reference)
        case .keyword, .unit, .quantity: return FormulaColors.color(.keyword)
        case .rule: return FormulaColors.color(.lag)
        case .variable, .parameter: return FormulaColors.plain
        }
    }
}

// MARK: The AppKit text view

private struct FormulaTextArea: NSViewRepresentable {
    let text: String
    let diagnosedText: String?
    let diagnoses: [FormulaDiagnosis]
    let completions: (String, Int) -> (range: NSRange, items: [FormulaCompletion])
    let insertRequest: FormulaInsertRequest?
    let completion: FormulaCompletionState
    var onChange: (String) -> Void
    var onApply: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FormulaEditorContainer {
        let container = FormulaEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.attach(container)
        context.coordinator.update(self)
        textView.highlight(diagnoses: diagnosedText == text ? diagnoses : [])
        return container
    }

    func updateNSView(_ container: FormulaEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(self)
        let textView = container.textView
        if textView.string != text {
            // Revert, a fix or apply changed it from outside.
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            completion.dismiss()
        }
        let shown = diagnosedText == text ? diagnoses : []
        if shown != coordinator.drawnDiagnoses || textView.needsHighlight {
            textView.highlight(diagnoses: shown)
            coordinator.drawnDiagnoses = shown
            container.ruler.errorLines = Set(shown.compactMap { $0.severity == .error ? $0.line : nil })
            container.ruler.needsDisplay = true
        }
        if let request = insertRequest, request.id != coordinator.handledInsert {
            coordinator.handledInsert = request.id
            textView.window?.makeFirstResponder(textView)
            textView.insertText(request.text, replacementRange: textView.selectedRange())
            if request.caretBack > 0 {
                let location = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: max(0, location - request.caretBack), length: 0))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var drawnDiagnoses: [FormulaDiagnosis] = []
        var handledInsert: Int?
        private var parent: FormulaTextArea?
        private weak var container: FormulaEditorContainer?

        func attach(_ container: FormulaEditorContainer) {
            self.container = container
        }

        func update(_ parent: FormulaTextArea) {
            self.parent = parent
            guard let container else { return }
            let textView = container.textView
            textView.completion = parent.completion
            textView.completionSource = parent.completions
            textView.onApply = parent.onApply
            parent.completion.accept = { [weak textView] item in textView?.accept(item) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = container?.textView else { return }
            textView.highlight(diagnoses: [])
            drawnDiagnoses = []
            container?.ruler.errorLines = []
            container?.ruler.needsDisplay = true
            parent?.onChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = container?.textView, let completion = textView.completion, completion.isVisible else { return }
            let selection = textView.selectedRange()
            if selection.length > 0 || selection.location != NSMaxRange(completion.range) { textView.updateCompletions() }
        }
    }
}

/// Holds the scroll view so the completion list can be placed in top-left coordinates.
final class FormulaEditorContainer: NSView {
    let scrollView = NSScrollView()
    let textView = FormulaTextView(usingTextLayoutManager: false)
    let ruler: LineNumberRuler

    override var isFlipped: Bool { true }

    init() {
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 10)
        scrollView.documentView = textView

        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    @objc private func scrolled() {
        ruler.needsDisplay = true
        textView.completion?.dismiss()
    }
}

/// The text view: plain text in SF Mono, coloured by `FormulaHighlighter`, with its own
/// completion list.
final class FormulaTextView: NSTextView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let lineHeight: CGFloat = 20

    var completion: FormulaCompletionState?
    var completionSource: ((String, Int) -> (range: NSRange, items: [FormulaCompletion]))?
    var onApply: (() -> Void)?
    /// Set when the text was replaced without a change notification.
    var needsHighlight = true

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        drawsBackground = false
        insertionPointColor = .white
        font = Self.font
        textColor = FormulaColors.plain
        defaultParagraphStyle = Self.paragraphStyle
        typingAttributes = [.font: Self.font, .foregroundColor: FormulaColors.plain, .paragraphStyle: Self.paragraphStyle]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        setAccessibilityLabel("Formula")
    }

    override var string: String {
        didSet { needsHighlight = true }
    }

    /// Colours the text and underlines the mistakes.
    func highlight(diagnoses: [FormulaDiagnosis]) {
        guard let storage = textStorage else { return }
        needsHighlight = false
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: FormulaColors.plain, .paragraphStyle: Self.paragraphStyle], range: full)
        for token in FormulaHighlighter.tokens(in: storage.string) where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: FormulaColors.color(token.kind), range: token.range)
        }
        for diagnosis in diagnoses {
            guard let range = diagnosis.range, range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            let color = diagnosis.severity == .error ? FormulaColors.error : FormulaColors.warning
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.union(.patternDot).rawValue, .underlineColor: color], range: range)
        }
        storage.endEditing()
        // A faint band behind lines with a mistake.
        if let layoutManager {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let lines = FormulaDiagnoser.lineRanges(storage.string)
            for diagnosis in diagnoses where diagnosis.severity == .error {
                guard let line = diagnosis.line, line >= 1, line <= lines.count else { continue }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: FormulaColors.error.withAlphaComponent(0.10),
                                                    forCharacterRange: lines[line - 1])
            }
        }
    }

    // MARK: Completion

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if let last = typed.unicodeScalars.last,
           CharacterSet.letters.contains(last) || CharacterSet.decimalDigits.contains(last) || last == "." || last == "_" {
            updateCompletions()
        } else {
            completion?.dismiss()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        if completion?.isVisible == true { updateCompletions() }
    }

    override func keyDown(with event: NSEvent) {
        if let completion, completion.isVisible {
            switch event.keyCode {
            case 125: completion.move(1); return                    // ↓
            case 126: completion.move(-1); return                   // ↑
            case 36, 76, 48:                                        // return, enter, tab
                if completion.items.indices.contains(completion.selected) { accept(completion.items[completion.selected]) }
                return
            case 53: completion.dismiss(); return                   // esc
            default: break
            }
        }
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onApply?()
            return
        }
        super.keyDown(with: event)
    }

    /// Esc closes the completion list, then leaves the editor. (NSTextView would otherwise open
    /// its own completion list.)
    override func cancelOperation(_ sender: Any?) {
        if let completion, completion.isVisible {
            completion.dismiss()
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    /// Shows what could go at the caret, or hides the list.
    func updateCompletions() {
        guard let completion, let completionSource else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { completion.dismiss(); return }
        let (range, items) = completionSource(string, selection.location)
        let afterDot = range.location > 0 && (string as NSString).character(at: range.location - 1) == 46
        guard !items.isEmpty, range.length > 0 || afterDot else {
            completion.dismiss()
            return
        }
        completion.range = range
        if completion.items.map(\.id) != items.map(\.id) {
            completion.items = items
            completion.selected = 0
        }
        completion.anchor = caretBottom(at: range.location)
    }

    /// Puts a choice in place of what was typed.
    func accept(_ item: FormulaCompletion) {
        guard let completion else { return }
        let range = completion.range
        completion.dismiss()
        guard NSMaxRange(range) <= (string as NSString).length else { return }
        insertText(item.text, replacementRange: range)
        if item.caretBack > 0 {
            let location = selectedRange().location
            setSelectedRange(NSRange(location: max(0, location - item.caretBack), length: 0))
        }
    }

    /// The bottom left of the line at `location`, in the container's top-left coordinates.
    private func caretBottom(at location: Int) -> CGPoint {
        guard let layoutManager, let textContainer, let container = enclosingScrollView?.superview else { return .zero }
        let length = (string as NSString).length
        var rect: NSRect
        if location >= length, length > 0, (string as NSString).character(at: length - 1) == 10 {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(length - 1, 0)))
            rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: length == 0 ? 0 : 1), in: textContainer)
            if location >= length, length > 0 { rect.origin.x = rect.maxX }
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        let converted = container.convert(rect, from: self)
        return CGPoint(x: converted.minX, y: converted.maxY)
    }
}

/// Line numbers beside the formula, red on lines with a mistake.
final class LineNumberRuler: NSRulerView {
    var errorLines: Set<Int> = []
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = 34
    }

    required init(coder: NSCoder) { fatalError("Not used") }

    override var requiredThickness: CGFloat { 34 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: "#111317").setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        var index = 0
        // Count the lines above the visible ones.
        while index < characters.location {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index <= characters.location { line += 1 }
        }
        index = string.lineRange(for: NSRange(location: min(characters.location, string.length), length: 0)).location
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func draw(_ number: Int, lineRect: NSRect) {
            let y = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView).y
            let color = errorLines.contains(number) ? FormulaColors.errorText : FormulaColors.lineNumber
            let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: color])
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2))
        }
        while index < string.length && index <= NSMaxRange(characters) {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            draw(line, lineRect: layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            line += 1
            index = NSMaxRange(range)
        }
        // The empty line after a final line break, or an empty formula.
        if !layoutManager.extraLineFragmentRect.isEmpty, index >= string.length {
            draw(line, lineRect: layoutManager.extraLineFragmentRect)
        }
    }
}
#endif
