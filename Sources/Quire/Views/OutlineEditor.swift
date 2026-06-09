import SwiftUI
import AppKit

/// A markdown-flavored outline editor backed by NSTextView.
/// Source format: each line is `<tabs>- [optional [ ] or [x]] body`.
/// Indentation via tabs.
///
/// Behavior:
///   • Enter on `- body` creates a new `- ` at the same indent.
///   • Enter on `- [ ] body` / `- [x] body` creates a fresh `- [ ] ` at the same indent.
///   • Enter on an empty `- ` outdents (or strips the bullet at indent 0).
///   • Enter on an empty `- [ ]` / `- [x]` strips the checkbox, keeps the bullet.
///   • Tab / Shift+Tab indent / outdent the current line.
///   • Click on a `[ ]` or `[x]` glyph toggles its state.
///
/// Live styling:
///   • The `-` character renders as a circular bullet dot (the `-` text is hidden).
///   • `- [ ]` / `- [x]` → checkbox graphic (suppresses the bullet for that line).
///   • `## title` → larger semibold title with dimmed `##`.
///   • `**bold**` → bold inner; `**` markers hidden.
struct OutlineEditor: NSViewRepresentable {
    @Binding var text: String
    var vimEngine: VimEngine?
    var timerStore: TimerStore?
    var pageDate: String = ""
    /// Bumped by TimerStore each second while a timer is active. Reading it here causes
    /// SwiftUI to re-invoke updateNSView, which redraws the editor (and the timer pill).
    var tick: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OutlineTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? OutlineTextView else {
            return scrollView
        }

        textView.coordinator = context.coordinator
        textView.vimEngine = vimEngine
        textView.timerStore = timerStore
        textView.pageDate = pageDate
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false

        textView.font = Coordinator.baseFont
        textView.textColor = Coordinator.ink
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = Coordinator.accent

        textView.defaultParagraphStyle = Coordinator.paragraphStyle
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.textContainer?.lineFragmentPadding = 0

        context.coordinator.isExternalUpdate = true
        textView.string = text
        context.coordinator.isExternalUpdate = false
        context.coordinator.applyStyles(textView)
        vimEngine?.refreshCursor(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? OutlineTextView else { return }
        textView.vimEngine = vimEngine
        textView.timerStore = timerStore
        textView.pageDate = pageDate
        // Force a redraw of the timer pills so the live timer keeps ticking visually.
        textView.setNeedsDisplay(textView.bounds)
        defer { vimEngine?.refreshCursor(in: textView) }
        if textView.string != text {
            let selected = textView.selectedRange()
            context.coordinator.isExternalUpdate = true
            textView.string = text
            context.coordinator.isExternalUpdate = false
            let length = (textView.string as NSString).length
            let safe = NSRange(
                location: min(selected.location, length),
                length: min(selected.length, max(0, length - min(selected.location, length)))
            )
            textView.setSelectedRange(safe)
            context.coordinator.applyStyles(textView)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: OutlineEditor
        private var isStyling = false
        var isExternalUpdate = false

        init(_ parent: OutlineEditor) { self.parent = parent }

        // MARK: - Style constants

        static let ink     = NSColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        static let muted   = NSColor(red: 0.330, green: 0.345, blue: 0.380, alpha: 1)
        static let dim     = NSColor(red: 0.580, green: 0.590, blue: 0.610, alpha: 1)
        static let accent  = NSColor(red: 0.722, green: 0.329, blue: 0.251, alpha: 1)

        static let baseFont    = NSFont.systemFont(ofSize: 14, weight: .regular)
        static let boldFont    = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let monoBracket = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        static let h1Font      = NSFont.systemFont(ofSize: 24, weight: .semibold)
        static let h2Font      = NSFont.systemFont(ofSize: 19, weight: .semibold)
        static let h3Font      = NSFont.systemFont(ofSize: 16, weight: .semibold)
        static let hiddenFont  = NSFont.systemFont(ofSize: 0.01)

        static let paragraphStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.tabStops = (1...30).map {
                NSTextTab(textAlignment: .left, location: CGFloat($0) * 18)
            }
            p.defaultTabInterval = 18
            p.lineSpacing = 3
            return p
        }()

        // MARK: - Delegate hooks

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isStyling || isExternalUpdate { return }
            parent.text = textView.string
            applyStyles(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): return handleEnter(textView)
            case #selector(NSResponder.insertTab(_:)):     return handleTab(textView, shift: false)
            case #selector(NSResponder.insertBacktab(_:)): return handleTab(textView, shift: true)
            default: return false
            }
        }

        // MARK: - Click toggle

        func handleClick(at index: Int, in textView: NSTextView) -> Bool {
            let storage = textView.string as NSString
            guard index >= 0, index < storage.length else { return false }
            let lineRange = storage.lineRange(for: NSRange(location: index, length: 0))
            let line = storage.substring(with: lineRange)

            guard let regex = try? NSRegularExpression(pattern: #"^\t*- (\[[ xX?]\])"#) else { return false }
            let lineLen = (line as NSString).length
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) else {
                return false
            }
            let groupRange = match.range(at: 1)
            let absRange = NSRange(location: lineRange.location + groupRange.location, length: groupRange.length)

            // Allow click within the bracket span (and one char of slack on each side for fat-finger).
            let slackStart = max(absRange.location - 1, 0)
            let slackEnd = min(absRange.upperBound + 1, storage.length)
            guard index >= slackStart && index < slackEnd else { return false }

            let current = (textView.string as NSString).substring(with: absRange).lowercased()
            // Cycle: [ ] → [x] → [?] → [ ]
            let cycled: String
            switch current {
            case "[ ]": cycled = "[x]"
            case "[x]": cycled = "[?]"
            case "[?]": cycled = "[ ]"
            default:    cycled = "[ ]"
            }
            let toggled = cycled
            if textView.shouldChangeText(in: absRange, replacementString: toggled) {
                textView.textStorage?.replaceCharacters(in: absRange, with: toggled)
                textView.didChangeText()
                parent.text = textView.string
                applyStyles(textView)
            }
            return true
        }

        // MARK: - Line parsing

        private struct ParsedLine {
            let indent: Int
            let hasBullet: Bool
            let isCheckbox: Bool
            let body: String
        }

        private func parseLine(_ line: String) -> ParsedLine? {
            guard let regex = try? NSRegularExpression(pattern: #"^(\t*)(- )?(\[[ xX?]\] )?(.*)$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            else { return nil }
            let nsLine = line as NSString
            let indent = match.range(at: 1).length
            let hasBullet = match.range(at: 2).location != NSNotFound
            let isCheckbox = match.range(at: 3).location != NSNotFound
            let body = nsLine.substring(with: match.range(at: 4))
            return ParsedLine(indent: indent, hasBullet: hasBullet, isCheckbox: isCheckbox, body: body)
        }

        // MARK: - Enter

        private func handleEnter(_ textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))

            var lineText = nsString.substring(with: lineRange)
            if lineText.hasSuffix("\n") { lineText.removeLast() }

            guard let parsed = parseLine(lineText) else { return false }

            let lineStart = lineRange.location
            let lineLen = (lineText as NSString).length

            // Empty checkbox: strip just the `[ ]`/`[x]` marker, keep the `- ` bullet and indent
            if parsed.isCheckbox && parsed.body.trimmingCharacters(in: .whitespaces).isEmpty {
                let replacement = String(repeating: "\t", count: parsed.indent) + "- "
                replace(textView: textView,
                        range: NSRange(location: lineStart, length: lineLen),
                        with: replacement,
                        cursorAbsolute: lineStart + (replacement as NSString).length)
                return true
            }

            // Empty bullet (no body, has `- ` but no checkbox):
            //   indent > 0 → outdent one level
            //   indent == 0 → strip the bullet (becomes a plain blank line)
            if parsed.hasBullet && !parsed.isCheckbox && parsed.body.trimmingCharacters(in: .whitespaces).isEmpty {
                let replacement: String
                if parsed.indent > 0 {
                    replacement = String(repeating: "\t", count: parsed.indent - 1) + "- "
                } else {
                    replacement = ""
                }
                replace(textView: textView,
                        range: NSRange(location: lineStart, length: lineLen),
                        with: replacement,
                        cursorAbsolute: lineStart + (replacement as NSString).length)
                return true
            }

            // Otherwise: newline preserving indent + continuing markers
            let indentStr = String(repeating: "\t", count: parsed.indent)
            let insertion: String
            if parsed.isCheckbox {
                insertion = "\n\(indentStr)- [ ] "
            } else if parsed.hasBullet {
                insertion = "\n\(indentStr)- "
            } else if !indentStr.isEmpty {
                insertion = "\n\(indentStr)"
            } else {
                return false // default newline
            }
            textView.insertText(insertion, replacementRange: sel)
            return true
        }

        // MARK: - Tab

        private func handleTab(_ textView: NSTextView, shift: Bool) -> Bool {
            let nsString = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
            var lineText = nsString.substring(with: lineRange)
            let hadNewline = lineText.hasSuffix("\n")
            if hadNewline { lineText.removeLast() }

            let originalLen = (lineText as NSString).length
            if shift {
                guard lineText.hasPrefix("\t") else { return true } // consume; no-op
                lineText.removeFirst()
            } else {
                lineText = "\t" + lineText
            }
            let newLen = (lineText as NSString).length
            let delta = newLen - originalLen

            let cursorInLine = max(0, sel.location - lineRange.location)
            let replacement = lineText + (hadNewline ? "\n" : "")
            let newCursor = lineRange.location + min(max(0, cursorInLine + delta), newLen)
            replace(textView: textView, range: lineRange, with: replacement, cursorAbsolute: newCursor)
            return true
        }

        // MARK: - Replace helper

        private func replace(textView: NSTextView, range: NSRange, with text: String, cursorAbsolute: Int) {
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(cursorAbsolute, length), length: 0))
        }

        // MARK: - Styling

        func applyStyles(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            isStyling = true
            defer { isStyling = false }

            let string = storage.string
            let nsString = string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)

            storage.beginEditing()

            storage.setAttributes([
                .font: Self.baseFont,
                .foregroundColor: Self.ink,
                .paragraphStyle: Self.paragraphStyle
            ], range: fullRange)

            nsString.enumerateSubstrings(in: fullRange, options: .byLines) { (substring, lineRange, _, _) in
                guard let line = substring else { return }
                self.styleLine(line, range: lineRange, storage: storage)
            }

            // Inline: **bold**
            self.applyInline(pattern: #"\*\*([^*\n]+?)\*\*"#, in: storage) { match in
                let outer = match.range
                let inner = match.range(at: 1)
                storage.addAttribute(.font, value: Self.boldFont, range: inner)
                // Hide the `**` markers — near-zero-width font + clear color so they take
                // no visible space and don't print on screen, but stay in the text storage
                // for editing/saving.
                let lhs = NSRange(location: outer.location, length: 2)
                let rhs = NSRange(location: outer.upperBound - 2, length: 2)
                self.hideRange(lhs, in: storage)
                self.hideRange(rhs, in: storage)
            }

            // Inline: [text](url) — visible label is accent-colored + underlined; the brackets,
            // closing `](url)` are hidden so the line reads as just the label.
            self.applyInline(pattern: #"\[([^\]\n]+?)\]\(([^)\n]+?)\)"#, in: storage) { match in
                let outer = match.range
                let textRange = match.range(at: 1)

                storage.addAttribute(.foregroundColor, value: Self.accent, range: textRange)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                storage.addAttribute(.underlineColor, value: Self.accent, range: textRange)

                // Hide the leading `[`.
                self.hideRange(NSRange(location: outer.location, length: 1), in: storage)
                // Hide everything from `]` through the closing `)`.
                let suffixStart = textRange.upperBound
                let suffixLength = outer.upperBound - suffixStart
                if suffixLength > 0 {
                    self.hideRange(NSRange(location: suffixStart, length: suffixLength), in: storage)
                }
            }

            storage.endEditing()
        }

        private func hideRange(_ range: NSRange, in storage: NSTextStorage) {
            storage.addAttribute(.font, value: Self.hiddenFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }

        private func styleLine(_ line: String, range lineRange: NSRange, storage: NSTextStorage) {
            let nsLine = line as NSString
            let lineLen = nsLine.length
            guard lineLen > 0 else { return }
            // Heading: "# title" / "## title" / "### title" — with or without a leading "- "
            if let regex = try? NSRegularExpression(pattern: #"^(\t*)(- )?(#{1,3})\s(.*)$"#),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) {
                let dashRange = match.range(at: 2)
                let hashRange = match.range(at: 3)
                let titleRange = match.range(at: 4)

                // Hide the `-` text (a bullet dot is drawn over it). Only if the prefix matched.
                if dashRange.location != NSNotFound {
                    let dashCharRange = NSRange(location: lineRange.location + dashRange.location, length: 1)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: dashCharRange)
                }

                // Hide the `#`/`##`/`###` markers AND the trailing space (regex matched `\s`)
                // with a near-zero-width font so they take no room on screen but stay in the
                // text for editing.
                let markerRange = NSRange(
                    location: lineRange.location + hashRange.location,
                    length: hashRange.length + 1
                )
                storage.addAttribute(.font, value: Self.hiddenFont, range: markerRange)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: markerRange)

                let level = hashRange.length
                let headingFont: NSFont = {
                    switch level {
                    case 1:  return Self.h1Font
                    case 2:  return Self.h2Font
                    default: return Self.h3Font
                    }
                }()

                if titleRange.length > 0 {
                    let absTitle = NSRange(location: lineRange.location + titleRange.location, length: titleRange.length)
                    storage.addAttribute(.font, value: headingFont, range: absTitle)
                    storage.addAttribute(.foregroundColor, value: Self.ink, range: absTitle)
                }
                return
            }

            // Checkbox bullet: "- [ ] body" or "- [x] body" (possibly indented with tabs)
            if let regex = try? NSRegularExpression(pattern: #"^(\t*)(- )(\[[ xX?]\])( .*)?$"#),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) {
                let dashRange = match.range(at: 2)
                let checkRange = match.range(at: 3)
                let bodyRange = match.range(at: 4)

                // Hide the entire `- ` prefix (no bullet dot for checkbox lines — the checkbox
                // graphic replaces it). Use a near-zero-width font so the chars take no width.
                let absDash = NSRange(location: lineRange.location + dashRange.location, length: dashRange.length)
                storage.addAttribute(.font, value: Self.hiddenFont, range: absDash)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: absDash)

                // Hide the bracket glyphs. Use monospace so `[ ]` and `[x]` are the same width
                // (without it, `x` is wider than a space in a proportional font).
                let absCheck = NSRange(location: lineRange.location + checkRange.location, length: checkRange.length)
                storage.addAttribute(.font, value: Self.monoBracket, range: absCheck)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: absCheck)

                let checkText = nsLine.substring(with: checkRange).lowercased()
                let isChecked = (checkText == "[x]")
                let isWaiting = (checkText == "[?]")

                if bodyRange.location != NSNotFound, bodyRange.length > 0 {
                    let absBody = NSRange(location: lineRange.location + bodyRange.location, length: bodyRange.length)
                    if isChecked {
                        // Dim the whole body but only strikethrough past the leading space.
                        storage.addAttribute(.foregroundColor, value: Self.dim, range: absBody)
                        if absBody.length > 1 {
                            let strikeRange = NSRange(location: absBody.location + 1, length: absBody.length - 1)
                            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: strikeRange)
                            storage.addAttribute(.strikethroughColor, value: Self.dim, range: strikeRange)
                        }
                    } else if isWaiting {
                        // Subtle mid-tone tint — not as faded as done, but visually de-prioritized.
                        storage.addAttribute(.foregroundColor, value: Self.muted, range: absBody)
                    }
                }
                return
            }

            // Plain bullet line: "- body" or just "-" (possibly indented with tabs)
            if let regex = try? NSRegularExpression(pattern: #"^(\t*)(-)(?:( |$).*)?$"#),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) {
                let dashRange = match.range(at: 2)
                // Hide the `-` character; OutlineTextView.draw(_:) paints a bullet dot over it.
                let absDash = NSRange(location: lineRange.location + dashRange.location, length: dashRange.length)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: absDash)
                return
            }
        }

        private func applyInline(pattern: String, in storage: NSTextStorage, body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let string = storage.string
            let range = NSRange(location: 0, length: (string as NSString).length)
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let m = match { body(m) }
            }
        }
    }
}

// MARK: - NSTextView subclass with checkbox rendering + click-to-toggle

final class OutlineTextView: NSTextView {
    weak var coordinator: OutlineEditor.Coordinator?
    weak var vimEngine: VimEngine?
    weak var timerStore: TimerStore?
    var pageDate: String = ""

    override func keyDown(with event: NSEvent) {
        if vimEngine?.handle(event: event, in: self) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Catch ⌘B before menu / default handling — toggle markdown bold around the selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command,
           event.charactersIgnoringModifiers?.lowercased() == "b",
           window?.firstResponder === self {
            toggleMarkdownBold()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Smart paste: if the clipboard holds a URL AND there's a non-empty selection, wrap the
    /// selection as `[selection](url)`. Otherwise, defer to the normal paste behavior.
    override func paste(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0,
           let raw = NSPasteboard.general.string(forType: .string),
           let url = Self.linkURLString(from: raw) {
            let selectedText = (string as NSString).substring(with: sel)
            let wrapped = "[\(selectedText)](\(url))"
            guard shouldChangeText(in: sel, replacementString: wrapped) else { return }
            replaceCharacters(in: sel, with: wrapped)
            didChangeText()
            let cursorPos = sel.location + (wrapped as NSString).length
            setSelectedRange(NSRange(location: cursorPos, length: 0))
            return
        }
        super.paste(sender)
    }

    /// Returns the trimmed URL string if `raw` looks like a single URL (http/https), nil otherwise.
    private static func linkURLString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains(" "), !trimmed.contains(")") else {
            return nil
        }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return trimmed
    }

    private func toggleMarkdownBold() {
        let sel = selectedRange()
        let nsString = string as NSString

        if sel.length == 0 {
            // No selection — insert `**` `**` and park the cursor between them.
            let insertion = "****"
            guard shouldChangeText(in: sel, replacementString: insertion) else { return }
            replaceCharacters(in: sel, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + 2, length: 0))
            return
        }

        let selected = nsString.substring(with: sel)
        let replacement: String
        let newLength: Int
        if selected.count >= 4, selected.hasPrefix("**"), selected.hasSuffix("**") {
            // Toggle off — drop the surrounding `**`.
            replacement = String(selected.dropFirst(2).dropLast(2))
            newLength = (replacement as NSString).length
        } else {
            // Wrap with `**`.
            replacement = "**\(selected)**"
            newLength = (replacement as NSString).length
        }

        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        replaceCharacters(in: sel, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location, length: newLength))
    }

    /// macOS routes Esc through `cancelOperation(_:)` in some configurations (interpretKeyEvents
    /// dispatch). Catch it here too so vim's `Esc → normal` always works.
    override func cancelOperation(_ sender: Any?) {
        if let vim = vimEngine, vim.isEnabled {
            vim.enterNormalMode()
            return
        }
        super.cancelOperation(sender)
    }

    private static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^\t*- (\[[ xX?]\])"#,
        options: .anchorsMatchLines
    )

    // Match plain bullets (`-` at line start, after tabs) that are NOT followed by a checkbox.
    // We capture the dash position to draw a bullet dot there.
    private static let bulletRegex = try! NSRegularExpression(
        pattern: #"^(\t*)(-)(?: (?!\[[ xX?]\])|$)"#,
        options: .anchorsMatchLines
    )

    // Style colors
    private static let muted  = NSColor(red: 0.330, green: 0.345, blue: 0.380, alpha: 1)
    private static let accent = NSColor(red: 0.722, green: 0.329, blue: 0.251, alpha: 1)
    private static let paper  = NSColor(red: 0.992, green: 0.991, blue: 0.987, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBullets(in: dirtyRect)
        drawCheckboxes(in: dirtyRect)
        drawTimers(in: dirtyRect)
    }

    // MARK: - Timer pills

    private static let timerPillWidth: CGFloat = 56
    private static let timerPillHeight: CGFloat = 18
    private static let timerPillRightInset: CGFloat = 8

    private func drawTimers(in dirtyRect: NSRect) {
        guard let timerStore = timerStore,
              let layoutManager = layoutManager,
              let container = textContainer,
              let textStorage = textStorage,
              !pageDate.isEmpty else { return }

        let string = textStorage.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return }

        let inset = textContainerOrigin

        Self.checkboxRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match = match else { return }
            let bracketRange = match.range(at: 1)

            // Map the bracket to its full line, to compute vertical centering and extract task key.
            let lineRange = nsString.lineRange(for: bracketRange)
            let lineText = nsString.substring(with: lineRange)
            let taskKey = Self.taskKey(fromLine: lineText)
            guard !taskKey.isEmpty else { return }

            // Compute the line's vertical rect from the bracket glyph rect (single-line bullet).
            let glyphRange = layoutManager.glyphRange(forCharacterRange: bracketRange, actualCharacterRange: nil)
            let bracketRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let centerY = bracketRect.midY + inset.y

            let pill = NSRect(
                x: bounds.width - Self.timerPillWidth - Self.timerPillRightInset,
                y: centerY - Self.timerPillHeight / 2,
                width: Self.timerPillWidth,
                height: Self.timerPillHeight
            )
            guard dirtyRect.intersects(pill) else { return }

            let isActive = timerStore.isActive(taskKey: taskKey, pageDate: pageDate)
            let totalSeconds = timerStore.totalSeconds(taskKey: taskKey, pageDate: pageDate)
            let label = (totalSeconds <= 0 && !isActive) ? "▶" : Self.formatDuration(totalSeconds)

            drawPill(in: pill, label: label, isActive: isActive)
        }
    }

    private func drawPill(in rect: NSRect, label: String, isActive: Bool) {
        let bg = isActive
            ? NSColor(red: 0.722, green: 0.329, blue: 0.251, alpha: 0.92)
            : NSColor(red: 0.870, green: 0.865, blue: 0.855, alpha: 0.80)
        let fg = isActive
            ? NSColor(red: 0.992, green: 0.991, blue: 0.987, alpha: 1.0)
            : NSColor(red: 0.330, green: 0.345, blue: 0.380, alpha: 1.0)

        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        bg.setFill()
        path.fill()

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
        ]
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let size = attributed.size()
        let textRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: textRect)
    }

    /// Strips the bullet + checkbox markers from a line, returning the body text used as the
    /// stable timer key. e.g., `\t- [ ] reply to professor\n` → `reply to professor`.
    fileprivate static func taskKey(fromLine line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^\t*- \[[ xX?]\] (.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return "" }
        let body = (line as NSString).substring(with: match.range(at: 1))
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 {
            return "\(h)h\(m)m"
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Returns the timer pill rect for the checkbox line at the given character index,
    /// or nil if the index isn't on a checkbox line.
    fileprivate func timerPillRect(forCharacterAt index: Int) -> (rect: NSRect, taskKey: String)? {
        guard let layoutManager,
              let container = textContainer,
              let storage = textStorage else { return nil }

        let nsString = storage.string as NSString
        guard index < nsString.length else { return nil }

        let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
        let line = nsString.substring(with: lineRange)
        let taskKey = Self.taskKey(fromLine: line)
        guard !taskKey.isEmpty else { return nil }

        // Find the bracket range on this line to anchor the pill vertically.
        guard let regex = try? NSRegularExpression(pattern: #"^\t*- (\[[ xX?]\])"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let bracketRange = NSRange(
            location: lineRange.location + match.range(at: 1).location,
            length: match.range(at: 1).length
        )
        let glyphRange = layoutManager.glyphRange(forCharacterRange: bracketRange, actualCharacterRange: nil)
        let bracketRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let centerY = bracketRect.midY + textContainerOrigin.y

        let pill = NSRect(
            x: bounds.width - Self.timerPillWidth - Self.timerPillRightInset,
            y: centerY - Self.timerPillHeight / 2,
            width: Self.timerPillWidth,
            height: Self.timerPillHeight
        )
        return (pill, taskKey)
    }

    private func drawBullets(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager,
              let container = textContainer,
              let textStorage = textStorage
        else { return }

        let string = textStorage.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return }

        let inset = textContainerOrigin

        Self.bulletRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match = match else { return }
            let dashRange = match.range(at: 2)

            let glyphRange = layoutManager.glyphRange(forCharacterRange: dashRange, actualCharacterRange: nil)
            let dashRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            // Use the line fragment to position the bullet vertically with the text baseline.
            let drawRect = dashRect.offsetBy(dx: inset.x, dy: inset.y)
            _ = nsString  // (kept for future use; suppresses unused warning)

            guard dirtyRect.intersects(drawRect) else { return }
            drawBullet(in: drawRect)
        }
    }

    private func drawCheckboxes(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager,
              let container = textContainer,
              let textStorage = textStorage
        else { return }

        let string = textStorage.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return }

        let inset = textContainerOrigin

        Self.checkboxRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match = match else { return }
            let bracketRange = match.range(at: 1)

            let glyphRange = layoutManager.glyphRange(forCharacterRange: bracketRange, actualCharacterRange: nil)
            let bracketRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let drawRect = bracketRect.offsetBy(dx: inset.x, dy: inset.y)

            guard dirtyRect.intersects(drawRect) else { return }

            let bracketText = nsString.substring(with: bracketRange).lowercased()
            let state: CheckboxState
            switch bracketText {
            case "[x]": state = .done
            case "[?]": state = .waiting
            default:    state = .todo
            }
            drawCheckbox(in: drawRect, state: state)
        }
    }

    private enum CheckboxState { case todo, done, waiting }

    private static let waitingColor = NSColor(red: 0.831, green: 0.612, blue: 0.227, alpha: 1.0)

    private func drawBullet(in cellRect: NSRect) {
        let size: CGFloat = 5
        let dot = NSRect(
            x: cellRect.midX - size / 2,
            y: cellRect.midY - size / 2,
            width: size,
            height: size
        )
        let path = NSBezierPath(ovalIn: dot)
        Self.muted.setFill()
        path.fill()
    }

    private func drawCheckbox(in cellRect: NSRect, state: CheckboxState) {
        let size: CGFloat = 14
        let box = NSRect(
            x: cellRect.minX + 1,
            y: cellRect.midY - size / 2,
            width: size,
            height: size
        )

        switch state {
        case .done:
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            Self.accent.setFill()
            path.fill()
            let check = NSBezierPath()
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: box.minX + 3.0, y: box.midY + 0.5))
            check.line(to: NSPoint(x: box.midX - 0.5, y: box.maxY - 3.5))
            check.line(to: NSPoint(x: box.maxX - 2.5, y: box.minY + 3.5))
            Self.paper.setStroke()
            check.stroke()

        case .waiting:
            // Hollow amber circle — distinct shape from the empty square so it reads
            // as "different state, not just not-yet-checked".
            let circle = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
            circle.lineWidth = 1.6
            Self.waitingColor.setStroke()
            circle.stroke()

        case .todo:
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            path.lineWidth = 1.3
            Self.muted.setStroke()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        defer { vimEngine?.refreshCursor(in: self) }
        let pointInView = convert(event.locationInWindow, from: nil)

        // Timer pill — check before any text-related routing so a click in the right gutter
        // toggles the timer instead of placing the cursor at the end of the line.
        if let timerStore = timerStore, !pageDate.isEmpty,
           let layoutManager,
           let container = textContainer {
            let origin = textContainerOrigin
            let containerPoint = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if let (pill, taskKey) = timerPillRect(forCharacterAt: charIndex),
               pill.insetBy(dx: -2, dy: -2).contains(pointInView) {
                timerStore.toggle(taskKey: taskKey, pageDate: pageDate)
                setNeedsDisplay(bounds)
                return
            }
        }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(
            x: pointInView.x - origin.x,
            y: pointInView.y - origin.y
        )

        if let layoutManager,
           let container = textContainer,
           let storage = textStorage {
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let nsString = storage.string as NSString

            if charIndex < nsString.length,
               let regex = try? NSRegularExpression(pattern: #"^\t*- (\[[ xX?]\])"#) {
                let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
                let line = nsString.substring(with: lineRange)
                if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let groupRange = match.range(at: 1)
                    let absRange = NSRange(location: lineRange.location + groupRange.location, length: groupRange.length)

                    let bracketGlyphRange = layoutManager.glyphRange(forCharacterRange: absRange, actualCharacterRange: nil)
                    let bracketRect = layoutManager.boundingRect(forGlyphRange: bracketGlyphRange, in: container)

                    // Visible checkbox graphic rect — must match drawCheckbox math.
                    let checkboxSize: CGFloat = 14
                    let graphicRect = NSRect(
                        x: bracketRect.minX + 1,
                        y: bracketRect.midY - checkboxSize / 2,
                        width: checkboxSize,
                        height: checkboxSize
                    ).insetBy(dx: -3, dy: -3) // small click slack

                    // Click landed on the checkbox graphic → toggle, don't move the cursor.
                    if graphicRect.contains(containerPoint) {
                        _ = coordinator?.handleClick(at: absRange.location, in: self)
                        return
                    }

                    // Click landed inside the invisible bracket character range but NOT on the
                    // graphic → place the cursor just past the brackets so typing goes into the
                    // body, not into the hidden marker characters.
                    if charIndex >= absRange.location && charIndex < absRange.upperBound {
                        if window?.firstResponder !== self {
                            window?.makeFirstResponder(self)
                        }
                        setSelectedRange(NSRange(location: absRange.upperBound, length: 0))
                        return
                    }
                }
            }
        }

        super.mouseDown(with: event)
    }
}
