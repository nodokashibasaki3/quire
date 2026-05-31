import SwiftUI

struct ContentView: View {
    @Environment(TodoStore.self) private var store
    @Environment(VimEngine.self) private var vim
    @Environment(TimerStore.self) private var timers
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.rule)
            editor
        }
        .background(Color.paper)
        .preferredColorScheme(.light)
        .frame(minWidth: 600, minHeight: 640)
        .onAppear { draft = store.content }
        .onChange(of: store.currentDate) { _, _ in draft = store.content }
        .onChange(of: store.content) { _, new in
            // Reflect external changes (carry-forward seeding, etc.) into the editor.
            if new != draft { draft = new }
        }
        .onChange(of: draft) { _, new in
            store.updateContent(new)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                DateNavigatorView()
                Spacer()
                if vim.isEnabled {
                    vimModePill
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrowText)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(store.isToday ? Color.accentPersimmon : Color.inkSecondary)

                Text(DateHelpers.longLabel(for: store.currentDate))
                    .font(.system(size: 38, weight: .light))
                    .tracking(-0.5)
                    .foregroundStyle(Color.ink)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 32)
        .padding(.bottom, 18)
    }

    private var vimModePill: some View {
        let isNormal = (vim.mode == .normal)
        let fg = isNormal ? Color.paper : Color.ink
        let bg = isNormal ? Color.accentPersimmon : Color.rule.opacity(0.6)
        return Text(vim.mode.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
            .animation(.easeInOut(duration: 0.10), value: vim.mode)
    }

    private var eyebrowText: String {
        if let relative = DateHelpers.relativeLabel(for: store.currentDate) {
            return relative
        }
        return DateHelpers.weekday(for: store.currentDate)
    }

    // MARK: - Editor

    private var editor: some View {
        OutlineEditor(
            text: $draft,
            vimEngine: vim,
            timerStore: timers,
            pageDate: store.currentDate,
            // Observing tick here forces SwiftUI to re-call updateNSView every second,
            // which lets the editor re-draw the live timer pill.
            tick: timers.tick
        )
        .padding(.horizontal, 36)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }
}

extension Color {
    static let paper            = Color(red: 0.992, green: 0.991, blue: 0.987)
    static let ink              = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let inkSecondary     = Color(red: 0.330, green: 0.345, blue: 0.380)
    static let inkTertiary      = Color(red: 0.580, green: 0.590, blue: 0.610)
    static let rule             = Color(red: 0.870, green: 0.865, blue: 0.855)
    static let accentPersimmon  = Color(red: 0.722, green: 0.329, blue: 0.251)
    static let carriedTint      = Color(red: 0.953, green: 0.918, blue: 0.882)
}
