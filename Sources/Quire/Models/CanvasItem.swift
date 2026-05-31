import Foundation

struct CanvasItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let courseName: String
    let dueAt: Date?
    let htmlURL: URL?
}
