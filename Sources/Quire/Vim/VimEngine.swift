import Foundation
import AppKit
import Observation

/// A small vim emulator scoped to daily editing in the outline.
/// Covers: i/I/a/A/o/O (insert), Esc (normal), v/V (visual / visual line),
/// motions hjkl, w, b, 0, ^, $, gg, G, Enter, arrows,
/// edits x, dd, yy, p/P, u, plus d/y/c/x in visual mode.
@MainActor
@Observable
final class VimEngine {
    enum Mode: String, Equatable {
        case insert = "INSERT"
        case normal = "NORMAL"
        case visual = "VISUAL"
        case visualLine = "V-LINE"
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            mode = isEnabled ? .normal : .insert
            resetTransientState()
        }
    }

    private(set) var mode: Mode

    private static let enabledKey = "vimModeEnabled"

    private var register: String = ""
    private var registerIsLinewise: Bool = false
    private var pendingOperator: PendingOperator?
    private var lastG: Bool = false

    /// Anchor point of the active visual selection (vim's "other end").
    private var visualAnchor: Int = 0
    /// Head of the active visual selection — the end that motions move.
    private var visualCursor: Int = 0

    private enum PendingOperator { case delete, yank }

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.mode = enabled ? .normal : .insert
    }

    func enterNormalMode() {
        guard isEnabled else { return }
        mode = .normal
        resetTransientState()
    }

    private func resetTransientState() {
        pendingOperator = nil
        lastG = false
    }

    // MARK: - Event entry

    /// Returns true if the engine consumed the event. The text view should not call super.
    func handle(event: NSEvent, in textView: NSTextView) -> Bool {
        let consumed = dispatchEvent(event, in: textView)
        if consumed && isEnabled {
            refreshCursor(in: textView)
            // Keep the cursor on-screen after vim motions / edits. NSTextView's
            // setSelectedRange doesn't auto-scroll, so j/k off the visible region
            // would silently move the cursor without scrolling.
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        return consumed
    }

    private func dispatchEvent(_ event: NSEvent, in textView: NSTextView) -> Bool {
        guard isEnabled else { return false }

        // Esc always returns to normal mode.
        if event.keyCode == 53 {
            if mode == .visual || mode == .visualLine {
                // Collapse to single cursor at the visual head.
                textView.setSelectedRange(NSRange(location: visualCursor, length: 0))
            }
            mode = .normal
            resetTransientState()
            return true
        }

        if mode == .insert {
            return false
        }

        // In normal / visual modes: skip events with modifier keys held so macOS handles them.
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { return false }

        // Special keys
        switch event.keyCode {
        case 36, 76: // Return, keypad enter
            moveDownToFirstNonBlank(in: textView)
            resetTransientState()
            return true
        case 48: // Tab — swallow in normal/visual modes
            resetTransientState()
            return true
        case 123: moveCursor(in: textView, delta: -1); return true // ←
        case 124: moveCursor(in: textView, delta: 1);  return true // →
        case 125: moveCursorVertically(in: textView, delta: 1); return true // ↓
        case 126: moveCursorVertically(in: textView, delta: -1); return true // ↑
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return true }
        for char in chars {
            switch mode {
            case .normal:                handleNormalKey(char, in: textView)
            case .visual, .visualLine:   handleVisualKey(char, in: textView)
            case .insert:                break // unreachable; insert returns earlier
            }
        }
        return true
    }

    // MARK: - Normal mode

    private func handleNormalKey(_ char: Character, in textView: NSTextView) {
        // Two-step commands first
        if lastG {
            lastG = false
            if char == "g" {
                moveToBufferStart(in: textView)
                pendingOperator = nil
                return
            }
        }
        if let op = pendingOperator, char == operatorChar(op) {
            switch op {
            case .delete: deleteLine(in: textView)
            case .yank:   yankLine(in: textView)
            }
            pendingOperator = nil
            return
        }

        switch char {
        case "g": lastG = true; pendingOperator = nil; return
        case "d": pendingOperator = .delete; return
        case "y": pendingOperator = .yank; return
        default: pendingOperator = nil
        }

        switch char {
        case "i": mode = .insert
        case "I": moveToFirstNonBlank(in: textView); mode = .insert
        case "a": moveCursor(in: textView, delta: 1); mode = .insert
        case "A": moveToLineEnd(in: textView); mode = .insert
        case "o": openLineBelow(in: textView); mode = .insert
        case "O": openLineAbove(in: textView); mode = .insert
        case "v": enterVisual(.visual, in: textView)
        case "V": enterVisual(.visualLine, in: textView)
        case "h": moveCursor(in: textView, delta: -1)
        case "j": moveCursorVertically(in: textView, delta: 1)
        case "k": moveCursorVertically(in: textView, delta: -1)
        case "l": moveCursor(in: textView, delta: 1)
        case "w": moveWordForward(in: textView)
        case "b": moveWordBackward(in: textView)
        case "0": moveToLineStart(in: textView)
        case "^": moveToFirstNonBlank(in: textView)
        case "$": moveToLineEnd(in: textView)
        case "G": moveToBufferEnd(in: textView)
        case "x": deleteCharUnderCursor(in: textView)
        case "p": paste(in: textView, after: true)
        case "P": paste(in: textView, after: false)
        case "u": textView.undoManager?.undo()
        default: break
        }
    }

    // MARK: - Visual mode

    private func handleVisualKey(_ char: Character, in textView: NSTextView) {
        if lastG {
            lastG = false
            if char == "g" {
                moveToBufferStart(in: textView)
                return
            }
        }

        switch char {
        case "g": lastG = true; return
        case "v":
            if mode == .visual { exitVisualToNormal(in: textView) }
            else { mode = .visual }
            return
        case "V":
            if mode == .visualLine { exitVisualToNormal(in: textView) }
            else { mode = .visualLine }
            return

        // Operators
        case "d", "x":
            deleteVisualSelection(in: textView, enterInsertAfter: false)
            return
        case "c":
            deleteVisualSelection(in: textView, enterInsertAfter: true)
            return
        case "y":
            yankVisualSelection(in: textView)
            exitVisualToNormal(in: textView)
            return

        // Motions
        case "h": moveCursor(in: textView, delta: -1)
        case "j": moveCursorVertically(in: textView, delta: 1)
        case "k": moveCursorVertically(in: textView, delta: -1)
        case "l": moveCursor(in: textView, delta: 1)
        case "w": moveWordForward(in: textView)
        case "b": moveWordBackward(in: textView)
        case "0": moveToLineStart(in: textView)
        case "^": moveToFirstNonBlank(in: textView)
        case "$": moveToLineEnd(in: textView)
        case "G": moveToBufferEnd(in: textView)
        default: break
        }
    }

    private func enterVisual(_ targetMode: Mode, in textView: NSTextView) {
        let position = textView.selectedRange().location
        visualAnchor = position
        visualCursor = position
        mode = targetMode
    }

    private func exitVisualToNormal(in textView: NSTextView) {
        let cursor = visualCursor
        mode = .normal
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
    }

    private func visualSelectionRange(in textView: NSTextView) -> NSRange {
        let nsString = textView.string as NSString
        let length = nsString.length

        let low = min(visualAnchor, visualCursor)
        let high = max(visualAnchor, visualCursor)

        if mode == .visualLine {
            let anchorLine = nsString.lineRange(for: NSRange(location: min(low, length), length: 0))
            let cursorLine = nsString.lineRange(for: NSRange(location: min(high, length), length: 0))
            return NSRange(
                location: anchorLine.location,
                length: cursorLine.upperBound - anchorLine.location
            )
        }
        // Charwise
        let upper = min(high + 1, length)
        return NSRange(location: low, length: max(0, upper - low))
    }

    private func deleteVisualSelection(in textView: NSTextView, enterInsertAfter: Bool) {
        let nsString = textView.string as NSString
        let range = visualSelectionRange(in: textView)
        guard range.length > 0 else {
            exitVisualToNormal(in: textView)
            return
        }
        let captured = nsString.substring(with: range)
        register = captured
        registerIsLinewise = (mode == .visualLine)
        if registerIsLinewise && !register.hasSuffix("\n") {
            register += "\n"
        }

        guard textView.shouldChangeText(in: range, replacementString: "") else {
            exitVisualToNormal(in: textView)
            return
        }
        textView.replaceCharacters(in: range, with: "")
        textView.didChangeText()

        let newLength = (textView.string as NSString).length
        let cursorPos = min(range.location, newLength)
        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
        mode = enterInsertAfter ? .insert : .normal
    }

    private func yankVisualSelection(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let range = visualSelectionRange(in: textView)
        guard range.length > 0 else { return }
        var captured = nsString.substring(with: range)
        if mode == .visualLine && !captured.hasSuffix("\n") {
            captured += "\n"
        }
        register = captured
        registerIsLinewise = (mode == .visualLine)
    }

    private func operatorChar(_ op: PendingOperator) -> Character {
        switch op {
        case .delete: return "d"
        case .yank:   return "y"
        }
    }

    // MARK: - Cursor primitives (mode-aware)

    private func currentCursor(in textView: NSTextView) -> Int {
        if mode == .visual || mode == .visualLine {
            return visualCursor
        }
        return textView.selectedRange().location
    }

    private func setCursor(to position: Int, in textView: NSTextView) {
        let length = (textView.string as NSString).length
        let clamped = max(0, min(length, position))

        if mode == .visual || mode == .visualLine {
            visualCursor = clamped
        } else {
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }

    // MARK: - Motions

    private func moveCursor(in textView: NSTextView, delta: Int) {
        setCursor(to: currentCursor(in: textView) + delta, in: textView)
    }

    private func moveCursorVertically(in textView: NSTextView, delta: Int) {
        let nsString = textView.string as NSString
        let length = nsString.length
        let current = min(currentCursor(in: textView), length)
        let currentLine = nsString.lineRange(for: NSRange(location: current, length: 0))
        let column = current - currentLine.location

        var targetLine = currentLine
        if delta > 0 {
            for _ in 0..<delta {
                if targetLine.upperBound >= length { break }
                targetLine = nsString.lineRange(for: NSRange(location: targetLine.upperBound, length: 0))
            }
        } else {
            for _ in 0..<(-delta) {
                if targetLine.location == 0 { break }
                targetLine = nsString.lineRange(for: NSRange(location: targetLine.location - 1, length: 0))
            }
        }
        let lineText = nsString.substring(with: targetLine)
        let lineLen = max(0, lineText.count - (lineText.hasSuffix("\n") ? 1 : 0))
        let newColumn = min(column, lineLen)
        setCursor(to: targetLine.location + newColumn, in: textView)
    }

    private func moveWordForward(in textView: NSTextView) {
        let chars = Array(textView.string)
        let count = chars.count
        var idx = currentCursor(in: textView)
        if idx < count, Self.isWordChar(chars[idx]) {
            while idx < count, Self.isWordChar(chars[idx]) { idx += 1 }
        } else {
            while idx < count, !Self.isWordChar(chars[idx]), !chars[idx].isWhitespace { idx += 1 }
        }
        while idx < count, chars[idx].isWhitespace { idx += 1 }
        setCursor(to: idx, in: textView)
    }

    private func moveWordBackward(in textView: NSTextView) {
        let chars = Array(textView.string)
        var idx = currentCursor(in: textView)
        guard idx > 0 else { return }
        idx -= 1
        while idx > 0, chars[idx].isWhitespace { idx -= 1 }
        if Self.isWordChar(chars[idx]) {
            while idx > 0, Self.isWordChar(chars[idx - 1]) { idx -= 1 }
        } else {
            while idx > 0, !Self.isWordChar(chars[idx - 1]), !chars[idx - 1].isWhitespace { idx -= 1 }
        }
        setCursor(to: idx, in: textView)
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    private func moveToLineStart(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = currentCursor(in: textView)
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        setCursor(to: lineRange.location, in: textView)
    }

    private func moveToFirstNonBlank(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = currentCursor(in: textView)
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let lineText = nsString.substring(with: lineRange)
        var offset = 0
        for ch in lineText {
            if ch.isWhitespace, ch != "\n" { offset += 1 } else { break }
        }
        setCursor(to: lineRange.location + offset, in: textView)
    }

    private func moveToLineEnd(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = currentCursor(in: textView)
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let lineText = nsString.substring(with: lineRange)
        let endOffset = lineText.hasSuffix("\n") ? lineText.count - 1 : lineText.count
        setCursor(to: lineRange.location + endOffset, in: textView)
    }

    private func moveDownToFirstNonBlank(in textView: NSTextView) {
        moveCursorVertically(in: textView, delta: 1)
        moveToFirstNonBlank(in: textView)
    }

    private func moveToBufferStart(in textView: NSTextView) {
        setCursor(to: 0, in: textView)
    }

    private func moveToBufferEnd(in textView: NSTextView) {
        let length = (textView.string as NSString).length
        setCursor(to: length, in: textView)
    }

    // MARK: - Normal-mode edits

    private func openLineBelow(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let lineText = nsString.substring(with: lineRange)
        let hasTrailingNewline = lineText.hasSuffix("\n")
        let insertPos = hasTrailingNewline ? lineRange.upperBound : nsString.length
        let prefix = hasTrailingNewline ? "" : "\n"
        let replacement = "\(prefix)\n"
        let target = NSRange(location: insertPos, length: 0)
        guard textView.shouldChangeText(in: target, replacementString: replacement) else { return }
        textView.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()
        let cursorPos = insertPos + prefix.count
        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
    }

    private func openLineAbove(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let insertPos = lineRange.location
        let replacement = "\n"
        let target = NSRange(location: insertPos, length: 0)
        guard textView.shouldChangeText(in: target, replacementString: replacement) else { return }
        textView.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: insertPos, length: 0))
    }

    private func deleteCharUnderCursor(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location
        guard current < nsString.length else { return }
        let range = NSRange(location: current, length: 1)
        guard textView.shouldChangeText(in: range, replacementString: "") else { return }
        register = nsString.substring(with: range)
        registerIsLinewise = false
        textView.replaceCharacters(in: range, with: "")
        textView.didChangeText()
    }

    private func deleteLine(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let captured = nsString.substring(with: lineRange)
        register = captured.hasSuffix("\n") ? captured : captured + "\n"
        registerIsLinewise = true
        guard textView.shouldChangeText(in: lineRange, replacementString: "") else { return }
        textView.replaceCharacters(in: lineRange, with: "")
        textView.didChangeText()
        let newLen = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(lineRange.location, newLen), length: 0))
    }

    private func yankLine(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location
        let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
        let captured = nsString.substring(with: lineRange)
        register = captured.hasSuffix("\n") ? captured : captured + "\n"
        registerIsLinewise = true
    }

    private func paste(in textView: NSTextView, after: Bool) {
        guard !register.isEmpty else { return }
        let nsString = textView.string as NSString
        let current = textView.selectedRange().location

        let insertPos: Int
        if registerIsLinewise {
            let lineRange = nsString.lineRange(for: NSRange(location: current, length: 0))
            insertPos = after ? lineRange.upperBound : lineRange.location
        } else {
            insertPos = after ? min(current + 1, nsString.length) : current
        }

        let target = NSRange(location: insertPos, length: 0)
        guard textView.shouldChangeText(in: target, replacementString: register) else { return }
        textView.replaceCharacters(in: target, with: register)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: insertPos, length: 0))
    }

    // MARK: - Visual cursor / selection refresh

    private static let blockBackgroundColor = NSColor(red: 0.722, green: 0.329, blue: 0.251, alpha: 0.92)
    private static let blockForegroundColor = NSColor(red: 0.992, green: 0.991, blue: 0.987, alpha: 1.0)
    private static let visualBackgroundColor = NSColor(red: 0.722, green: 0.329, blue: 0.251, alpha: 0.28)

    /// Reconciles the text view's selection / colors with the engine's current mode and state.
    /// Safe to call repeatedly — idempotent.
    func refreshCursor(in textView: NSTextView) {
        guard isEnabled else {
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor.selectedTextBackgroundColor
            ]
            return
        }

        switch mode {
        case .normal:
            textView.selectedTextAttributes = [
                .backgroundColor: Self.blockBackgroundColor,
                .foregroundColor: Self.blockForegroundColor,
            ]
            let nsString = textView.string as NSString
            let length = nsString.length
            let current = textView.selectedRange()
            if current.length == 0, current.location < length {
                let charAt = nsString.character(at: current.location)
                if charAt != 0x0A && charAt != 0x0D {
                    textView.setSelectedRange(NSRange(location: current.location, length: 1))
                }
            } else if current.length == 1 {
                let charAt = nsString.character(at: current.location)
                if charAt == 0x0A || charAt == 0x0D {
                    textView.setSelectedRange(NSRange(location: current.location, length: 0))
                }
            }

        case .insert:
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor.selectedTextBackgroundColor
            ]
            let current = textView.selectedRange()
            if current.length > 0 {
                textView.setSelectedRange(NSRange(location: current.location, length: 0))
            }

        case .visual, .visualLine:
            textView.selectedTextAttributes = [
                .backgroundColor: Self.visualBackgroundColor
            ]
            let range = visualSelectionRange(in: textView)
            textView.setSelectedRange(range)
        }
    }
}
