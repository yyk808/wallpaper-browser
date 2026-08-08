import Foundation

struct DownloadMetadataEntry: Codable, Hashable, Sendable {
  let workshopID: String
  var downloadedAt: Date
  var localPath: String?
}

@MainActor
final class DownloadMetadataStore {
  private var entries: [String: DownloadMetadataEntry]

  init() {
    entries = Self.loadEntries()
  }

  var count: Int { entries.count }

  func contains(_ workshopID: String) -> Bool {
    entries[workshopID] != nil
  }

  func recordDownload(workshopID: String, downloadedAt: Date, localPath: String?) {
    entries[workshopID] = DownloadMetadataEntry(
      workshopID: workshopID,
      downloadedAt: downloadedAt,
      localPath: localPath
    )
    persist()
  }

  func mergeCompletedRecords(_ records: [DownloadRecord]) {
    var didChange = false
    for record in records where record.phase == .completed {
      guard entries[record.id] == nil else { continue }
      entries[record.id] = DownloadMetadataEntry(
        workshopID: record.id,
        downloadedAt: record.completedAt ?? record.createdAt,
        localPath: record.localPath
      )
      didChange = true
    }
    if didChange { persist() }
  }

  func markLocalFileRemoved(workshopID: String) {
    guard entries[workshopID] != nil else { return }
    entries[workshopID]?.localPath = nil
    persist()
  }

  private func persist() {
    let sortedEntries = entries.values.sorted { $0.downloadedAt > $1.downloadedAt }
    guard let data = try? JSONEncoder().encode(sortedEntries) else { return }
    try? FileManager.default.createDirectory(
      at: Self.metadataURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: Self.metadataURL, options: .atomic)
  }

  private static func loadEntries() -> [String: DownloadMetadataEntry] {
    guard let data = try? Data(contentsOf: metadataURL),
      let decoded = try? JSONDecoder().decode([DownloadMetadataEntry].self, from: data)
    else { return [:] }
    return decoded.reduce(into: [:]) { result, entry in
      if let existing = result[entry.workshopID], existing.downloadedAt > entry.downloadedAt {
        return
      }
      result[entry.workshopID] = entry
    }
  }

  private static var metadataURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Wallpaper Browser/metadata.json")
  }
}
