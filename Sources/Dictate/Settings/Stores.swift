import DictateCore
import Foundation

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dictate", isDirectory: true)
    }
    /// In-flight and failed recordings awaiting retry.
    static var recordings: URL { ensure(support.appendingPathComponent("Recordings", isDirectory: true)) }
    /// Only used when "Keep audio history" is on.
    static var audioHistory: URL { ensure(support.appendingPathComponent("AudioHistory", isDirectory: true)) }
    static var transcriptHistoryFile: URL { ensure(support).appendingPathComponent("history.json") }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// A recording kept on disk so a failed transcription can be retried without re-recording.
struct PendingRecording: Codable, Equatable {
    var fileName: String
    var duration: Double
    var createdAt: Date
    var lastError: String?

    var url: URL { AppPaths.recordings.appendingPathComponent(fileName) }
    private var metadataURL: URL { url.appendingPathExtension("json") }

    func saveMetadata() {
        try? JSONEncoder().encode(self).write(to: metadataURL, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    /// Moves the audio into the history folder instead of deleting it.
    func archive() {
        let destination = AppPaths.audioHistory.appendingPathComponent(fileName)
        try? FileManager.default.moveItem(at: url, to: destination)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    /// Newest kept recording from a previous run; anything older than a day is removed.
    static func restoreOnLaunch() -> PendingRecording? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: AppPaths.recordings, includingPropertiesForKeys: nil)) ?? []
        var newest: PendingRecording?
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let pending = try? JSONDecoder().decode(PendingRecording.self, from: data),
                  fm.fileExists(atPath: pending.url.path) else {
                try? fm.removeItem(at: url)
                continue
            }
            if Date().timeIntervalSince(pending.createdAt) > 24 * 3600 {
                pending.delete()
            } else if newest == nil || pending.createdAt > newest!.createdAt {
                newest = pending
            }
        }
        // Audio without metadata was never handed to transcription (e.g. a crash mid-recording).
        for url in files where url.pathExtension == "m4a" && !fm.fileExists(atPath: url.path + ".json") {
            try? fm.removeItem(at: url)
        }
        return newest
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published private(set) var current: MonthlyUsage

    private init() {
        let stored = UserDefaults.standard.data(forKey: "usage").flatMap { try? JSONDecoder().decode(MonthlyUsage.self, from: $0) }
        current = (stored ?? MonthlyUsage(month: MonthlyUsage.monthKey(for: Date()))).rolledOver(to: Date())
    }

    func update(_ change: (inout MonthlyUsage) -> Void) {
        var usage = current.rolledOver(to: Date())
        change(&usage)
        current = usage
        UserDefaults.standard.set(try? JSONEncoder().encode(usage), forKey: "usage")
    }

    func reset() { update { $0 = MonthlyUsage(month: $0.month) } }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var appName: String?
}

/// Transcript history; off by default, and nothing is written unless the user enables it.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    private let limit = 50

    private init() {
        if let data = try? Data(contentsOf: AppPaths.transcriptHistoryFile) {
            entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    func add(_ text: String, appName: String?) {
        entries.insert(HistoryEntry(date: Date(), text: text, appName: appName), at: 0)
        entries = Array(entries.prefix(limit))
        persist()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: AppPaths.transcriptHistoryFile)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: AppPaths.transcriptHistoryFile, options: [.atomic, .completeFileProtection])
    }
}
