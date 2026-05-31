import SwiftUI
import AppKit

@main
struct QuireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap = Bootstrap()

    var body: some Scene {
        WindowGroup("Todos") {
            Group {
                if let store = bootstrap.store,
                   let sync = bootstrap.canvasSync,
                   let timers = bootstrap.timerStore {
                    ContentView()
                        .environment(store)
                        .environment(sync)
                        .environment(timers)
                        .environment(bootstrap.vimEngine)
                        .environment(bootstrap.pageStore)
                        .onAppear { sync.start() }
                } else {
                    FailureView()
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Canvas") {
                if let sync = bootstrap.canvasSync {
                    Button("Sync Now") {
                        Task { await sync.syncNow() }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!sync.isConfigured)

                    Divider()

                    Text(syncStatusLabel(for: sync.status))
                }
            }
            CommandMenu("Vim") {
                Button(bootstrap.vimEngine.isEnabled ? "Disable Vim Mode" : "Enable Vim Mode") {
                    bootstrap.vimEngine.isEnabled.toggle()
                }
                // ⌃⌥V — avoids conflict with macOS "Paste and Match Style" (⌘⇧V).
                .keyboardShortcut("v", modifiers: [.control, .option])

                if bootstrap.vimEngine.isEnabled {
                    Divider()
                    Text("Mode: \(bootstrap.vimEngine.mode.rawValue)")
                }
            }
        }

        Settings {
            if let sync = bootstrap.canvasSync, let store = bootstrap.store {
                AppSettingsView()
                    .environment(sync)
                    .environment(store)
                    .environment(bootstrap.pageStore)
            } else {
                Text("App failed to initialize.")
                    .padding()
            }
        }
    }

    private func syncStatusLabel(for status: CanvasSync.Status) -> String {
        switch status {
        case .idle:                       return "Not synced yet"
        case .syncing:                    return "Syncing…"
        case .success(let at, let added):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            let timeStr = formatter.string(from: at)
            return added == 0 ? "Up to date · \(timeStr)" : "+\(added) at \(timeStr)"
        case .error(let msg):             return "Error: \(msg)"
        }
    }
}

@MainActor
@Observable
final class Bootstrap {
    let store: TodoStore?
    let pageStore: PageFileStore
    let canvasSync: CanvasSync?
    let timerStore: TimerStore?
    let vimEngine: VimEngine
    let initError: String?

    init() {
        self.vimEngine = VimEngine()
        self.pageStore = PageFileStore()
        do {
            let store = try TodoStore(pageStore: pageStore)
            self.store = store
            let sync = CanvasSync(store: store)
            self.canvasSync = sync
            self.timerStore = TimerStore(dbQueue: store.dbQueue)
            self.initError = nil
            sync.start()
        } catch {
            self.store = nil
            self.canvasSync = nil
            self.timerStore = nil
            self.initError = error.localizedDescription
        }
    }
}

private struct FailureView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Could not open the todo database.")
                .font(.headline)
            Text("Check that ~/Library/Application Support is writable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
