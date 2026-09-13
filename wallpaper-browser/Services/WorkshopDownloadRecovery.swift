import Foundation

struct WorkshopManifestRepairOutcome: Sendable {
  let missingWorkshopID: String
  let missingFilename: String
}

struct WorkshopLogCheckpoint: Sendable {
  fileprivate let sizesByPath: [String: UInt64]
}

nonisolated enum WorkshopManifestStateRepair {
  private static let appID = "431960"
  private static let manifestName = "appworkshop_431960.acf"
  private static let repairableSections = ["WorkshopItemsInstalled", "WorkshopItemDetails"]

  static func checkpoint(in steamappsRoots: [URL]) -> WorkshopLogCheckpoint {
    let sizes = steamappsRoots.reduce(into: [String: UInt64]()) { result, root in
      let logURL = workshopLogURL(for: root)
      if let values = try? logURL.resourceValues(forKeys: [.fileSizeKey]),
        let size = values.fileSize
      {
        result[logURL.path] = UInt64(max(0, size))
      }
    }
    return WorkshopLogCheckpoint(sizesByPath: sizes)
  }

  static func repairMissingSource(
    in steamappsRoots: [URL],
    after checkpoint: WorkshopLogCheckpoint,
    requestedID: String
  ) async -> WorkshopManifestRepairOutcome? {
    await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      for root in steamappsRoots {
        let logURL = workshopLogURL(for: root)
        let offset = checkpoint.sizesByPath[logURL.path] ?? 0
        guard let text = contents(of: logURL, after: offset),
          text.contains("Download item \(requestedID)"),
          let missingURL = missingFileURL(from: text, steamappsRoot: root),
          !fileManager.fileExists(atPath: missingURL.path),
          let missingID = workshopID(from: missingURL, steamappsRoot: root),
          repairManifest(at: root, removing: missingID)
        else { continue }
        return WorkshopManifestRepairOutcome(
          missingWorkshopID: missingID,
          missingFilename: missingURL.lastPathComponent
        )
      }
      return nil
    }.value
  }

  static func removingItem(_ id: String, fromManifest text: String) -> (text: String, removed: Bool) {
    guard isValidWorkshopID(id) else { return (text, false) }
    var lines = text.components(separatedBy: "\n")
    var didRemove = false

    for section in repairableSections {
      guard let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"\(section)\"" }),
        let sectionOpen = nextNonemptyLine(after: sectionIndex, in: lines),
        lines[sectionOpen].trimmingCharacters(in: .whitespaces) == "{"
      else { continue }

      var depth = 1
      var index = sectionOpen + 1
      while index < lines.count, depth > 0 {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if depth == 1, trimmed == "\"\(id)\"",
          let itemOpen = nextNonemptyLine(after: index, in: lines),
          lines[itemOpen].trimmingCharacters(in: .whitespaces) == "{",
          let itemClose = closingBrace(startingAt: itemOpen, in: lines)
        {
          lines.removeSubrange(index...itemClose)
          didRemove = true
          break
        }
        depth += braceDelta(in: trimmed)
        index += 1
      }
    }
    return (lines.joined(separator: "\n"), didRemove)
  }

  private static func repairManifest(at steamappsRoot: URL, removing id: String) -> Bool {
    let fileManager = FileManager.default
    let manifestURL = steamappsRoot.appending(path: "workshop/\(manifestName)")
    guard let originalData = try? Data(contentsOf: manifestURL),
      let original = String(data: originalData, encoding: .utf8)
    else { return false }
    let repaired = removingItem(id, fromManifest: original)
    guard repaired.removed, let repairedData = repaired.text.data(using: .utf8) else { return false }

    // Keep a recoverable copy and avoid overwriting a manifest changed concurrently by Steam.
    let backupURL = manifestURL.appendingPathExtension("wallpaper-browser-backup")
    if !fileManager.fileExists(atPath: backupURL.path) {
      do {
        try originalData.write(to: backupURL, options: .atomic)
      } catch {
        return false
      }
    }
    guard (try? Data(contentsOf: manifestURL)) == originalData else { return false }
    do {
      try repairedData.write(to: manifestURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func contents(of url: URL, after offset: UInt64) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: offset <= size ? offset : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func workshopLogURL(for steamappsRoot: URL) -> URL {
    steamappsRoot.deletingLastPathComponent().appending(path: "logs/workshop_log.txt")
  }

  private static func missingFileURL(from log: String, steamappsRoot: URL) -> URL? {
    let expectedPrefix = steamappsRoot
      .appending(path: "workshop/content/\(appID)", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    for line in log.components(separatedBy: .newlines).reversed()
      where line.contains("[AppID \(appID)]")
        && line.localizedCaseInsensitiveContains("Missing game files")
    {
      let quotedValues = line.split(separator: "\"", omittingEmptySubsequences: false)
      for value in quotedValues.reversed() {
        let path = String(value)
        guard path.hasPrefix(expectedPrefix) else { continue }
        return URL(fileURLWithPath: path).standardizedFileURL
      }
    }
    return nil
  }

  private static func workshopID(from fileURL: URL, steamappsRoot: URL) -> String? {
    let contentRoot = steamappsRoot
      .appending(path: "workshop/content/\(appID)", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    guard fileURL.path.hasPrefix(contentRoot) else { return nil }
    let relative = fileURL.path.dropFirst(contentRoot.count)
    guard let id = relative.split(separator: "/").first.map(String.init), isValidWorkshopID(id) else {
      return nil
    }
    return id
  }

  private static func isValidWorkshopID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  private static func nextNonemptyLine(after index: Int, in lines: [String]) -> Int? {
    guard index + 1 < lines.count else { return nil }
    return (index + 1..<lines.count).first {
      !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private static func closingBrace(startingAt openingIndex: Int, in lines: [String]) -> Int? {
    var depth = 0
    for index in openingIndex..<lines.count {
      depth += braceDelta(in: lines[index])
      if depth == 0 { return index }
    }
    return nil
  }

  private static func braceDelta(in line: String) -> Int {
    line.reduce(into: 0) { result, character in
      if character == "{" { result += 1 }
      if character == "}" { result -= 1 }
    }
  }
}
