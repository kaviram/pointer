import AppKit
import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var promptName: String
    var promptTemplate: String
    var provider: Provider
    var model: String
    var response: String

    /// Filename of the sibling PNG, relative to the history directory.
    var imageFilename: String

    var firstLine: String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n").first else { return "" }
        return String(line)
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let directory: URL
    private var imageCache: [UUID: NSImage] = [:]

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pointer/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [HistoryEntry] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data)
            else { continue }
            loaded.append(entry)
        }
        entries = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        if let cached = imageCache[entry.id] { return cached }
        let url = directory.appendingPathComponent(entry.imageFilename)
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache[entry.id] = image
        return image
    }

    func search(_ query: String) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.response.localizedCaseInsensitiveContains(trimmed)
                || $0.promptName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - Writing

    func add(
        pngData: Data,
        promptName: String,
        promptTemplate: String,
        provider: Provider,
        model: String,
        response: String,
        limit: Int
    ) {
        let id = UUID()
        let imageFilename = "\(id.uuidString).png"
        let entry = HistoryEntry(
            id: id,
            createdAt: Date(),
            promptName: promptName,
            promptTemplate: promptTemplate,
            provider: provider,
            model: model,
            response: response,
            imageFilename: imageFilename
        )

        do {
            try pngData.write(to: directory.appendingPathComponent(imageFilename), options: .atomic)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entry)
            try data.write(
                to: directory.appendingPathComponent("\(id.uuidString).json"),
                options: .atomic
            )
        } catch {
            NSLog("Pointer: could not write history entry: %@", "\(error)")
            return
        }

        entries.insert(entry, at: 0)
        prune(limit: limit)
    }

    func delete(_ entry: HistoryEntry) {
        removeFiles(for: entry)
        entries.removeAll { $0.id == entry.id }
        imageCache[entry.id] = nil
    }

    func clearAll() {
        for entry in entries { removeFiles(for: entry) }
        entries.removeAll()
        imageCache.removeAll()
    }

    private func removeFiles(for entry: HistoryEntry) {
        let json = directory.appendingPathComponent("\(entry.id.uuidString).json")
        let png = directory.appendingPathComponent(entry.imageFilename)
        try? FileManager.default.removeItem(at: json)
        try? FileManager.default.removeItem(at: png)
    }

    private func prune(limit: Int) {
        guard limit > 0, entries.count > limit else { return }
        // entries is newest-first, so the tail is the oldest.
        let excess = entries[limit...]
        for entry in excess {
            removeFiles(for: entry)
            imageCache[entry.id] = nil
        }
        entries = Array(entries.prefix(limit))
    }
}
