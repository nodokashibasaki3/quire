import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "app.quire", category: "canvas")

@MainActor
@Observable
final class CanvasSync {
    enum Status: Equatable {
        case idle
        case syncing
        case success(at: Date, added: Int)
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var isConfigured: Bool = CanvasKeychain.load() != nil

    @ObservationIgnored private weak var store: TodoStore?
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    private static let syncInterval: UInt64 = 15 * 60 * 1_000_000_000 // 15 minutes in nanoseconds

    init(store: TodoStore) {
        self.store = store
    }

    /// Starts a background loop that syncs immediately and then every 15 minutes.
    /// Safe to call multiple times — cancels any prior loop first.
    func start() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncIfConfigured()
                try? await Task.sleep(nanoseconds: Self.syncInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func syncNow() async {
        await syncIfConfigured()
    }

    func refreshConfiguredFlag() {
        isConfigured = CanvasKeychain.load() != nil
    }

    private func syncIfConfigured() async {
        guard let credentials = CanvasKeychain.load() else {
            isConfigured = false
            return
        }
        isConfigured = true
        if case .syncing = status { return }
        status = .syncing

        let client = CanvasClient(credentials: credentials)
        do {
            let items = try await client.fetchUpcomingItems()
            let added = store?.applyCanvasItems(items) ?? 0
            log.info("Canvas sync added \(added) items")
            status = .success(at: Date(), added: added)
        } catch {
            log.error("Canvas sync failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
    }
}
