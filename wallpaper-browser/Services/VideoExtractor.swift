import AVFoundation
import Foundation

enum VideoExtractorError: LocalizedError {
  case missingProject
  case unsupportedType(String)
  case unsafePath
  case missingVideo

  var errorDescription: String? {
    switch self {
    case .missingProject: "extractor.error.missingProject"
    case .unsupportedType(let type): "extractor.error.unsupportedType|\(type)"
    case .unsafePath: "extractor.error.unsafePath"
    case .missingVideo: "extractor.error.missingVideo"
    }
  }
}

struct VideoExtractionResult: Sendable {
  let url: URL
  let needsThirdPartyPlayer: Bool
}

nonisolated struct VideoExtractor: Sendable {
  private static let videoExtensions = Set([
    "mp4", "m4v", "mov", "webm", "mkv", "avi", "mpg", "mpeg", "ts",
  ])

  func extract(
    from sourceDirectory: URL,
    item: WorkshopItem,
    to destinationDirectory: URL
  ) async throws -> VideoExtractionResult {
    let sourceDirectory = sourceDirectory.standardizedFileURL
    let resolvedSourceDirectory = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard sourceDirectory.path == resolvedSourceDirectory.path else {
      throw VideoExtractorError.unsafePath
    }

    let projectURL = sourceDirectory.appending(path: "project.json")
    let project: WorkshopProject?
    if let data = try? Data(contentsOf: projectURL) {
      project = try? JSONDecoder().decode(WorkshopProject.self, from: data)
    } else {
      project = nil
    }
    let projectVideoURL: URL? = project.flatMap { project in
      guard project.type.caseInsensitiveCompare("video") == .orderedSame else { return nil }
      return validatedVideoURL(
        sourceDirectory.appending(path: project.file),
        inside: resolvedSourceDirectory
      )
    }
    guard let videoURL = projectVideoURL ?? discoverVideo(in: resolvedSourceDirectory) else {
      throw VideoExtractorError.missingVideo
    }

    let asset = AVURLAsset(url: videoURL)
    var needsThirdPartyPlayer = (try? await asset.load(.isPlayable)) != true

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
    let projectTitle = project.flatMap {
      $0.type.caseInsensitiveCompare("video") == .orderedSame
        ? $0.title.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    let title = sanitizedFilename(projectTitle.flatMap { $0.isEmpty ? nil : $0 } ?? item.title)
    let destinationURL =
      destinationDirectory
      .appending(path: "\(title) [\(item.id)].\(ext)")
    let temporaryURL =
      destinationDirectory
      .appending(path: ".\(item.id)-\(UUID().uuidString).partial")

    do {
      do {
        // Keep Steam's workshop source intact so its manifest never points at a deleted file.
        // A hard link avoids storing the usually-large video twice when both folders share a volume.
        try fileManager.linkItem(at: videoURL, to: temporaryURL)
      } catch {
        try fileManager.copyItem(at: videoURL, to: temporaryURL)
      }
      if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      }
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }

    if needsThirdPartyPlayer {
      let playback = await VideoPlaybackCompatibility.shared.prepare(destinationURL)
      if playback?.url == destinationURL {
        needsThirdPartyPlayer = false
      }
      await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: playback)
    }
    return VideoExtractionResult(url: destinationURL, needsThirdPartyPlayer: needsThirdPartyPlayer)
  }

  private func validatedVideoURL(_ unresolvedURL: URL, inside sourceDirectory: URL) -> URL? {
    guard Self.videoExtensions.contains(unresolvedURL.pathExtension.lowercased()) else { return nil }
    let unresolvedValues = try? unresolvedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard unresolvedValues?.isSymbolicLink != true else { return nil }
    let resolvedURL = unresolvedURL.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedURL.path.hasPrefix(sourceDirectory.path + "/") else { return nil }
    let values = try? resolvedURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values?.isRegularFile == true,
      values?.isSymbolicLink != true,
      (values?.fileSize ?? 0) > 0
    else { return nil }
    return resolvedURL
  }

  private func discoverVideo(in sourceDirectory: URL) -> URL? {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: sourceDirectory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else { return nil }

    var largest: (url: URL, size: Int)?
    for case let candidate as URL in enumerator {
      guard Self.videoExtensions.contains(candidate.pathExtension.lowercased()),
        let videoURL = validatedVideoURL(candidate, inside: sourceDirectory),
        let values = try? videoURL.resourceValues(forKeys: Set(keys)),
        let size = values.fileSize,
        size > (largest?.size ?? 0)
      else { continue }
      largest = (videoURL, size)
    }
    return largest?.url
  }

  private func sanitizedFilename(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
    let cleaned =
      value
      .components(separatedBy: invalid)
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = cleaned.isEmpty ? "Wallpaper" : cleaned
    return String(fallback.prefix(120))
  }
}

private struct WorkshopProject: Decodable {
  let file: String
  let title: String
  let type: String
}
