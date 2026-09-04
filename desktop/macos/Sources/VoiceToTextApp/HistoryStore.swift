import Foundation

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
}

final class HistoryStore {
    private let key = "recognitionHistory"
    private let limit = 100
    private var items: [HistoryItem]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    var all: [HistoryItem] { items }

    @discardableResult
    func add(text: String) -> HistoryItem? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let item = HistoryItem(id: UUID(), createdAt: Date(), text: normalized)
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
        return item
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
