import AVFoundation
import Foundation

enum VideoExtractorError: LocalizedError {
  case missingProject
  case unsupportedType(String)
  case unsafePath
  case missingVideo
  case unplayableVideo

  var errorDescription: String? {
    switch self {
    case .missingProject: "下载内容中没有有效的 project.json。"
    case .unsupportedType(let type): "下载内容不是 Video 类型（\(type)）。"
    case .unsafePath: "project.json 指向了不安全的文件路径。"
    case .missingVideo: "找不到 project.json 指定的视频文件。"
    case .unplayableVideo: "该视频格式无法由 macOS 播放。"
    }
  }
}

nonisolated struct VideoExtractor: Sendable {
  func extract(
    from sourceDirectory: URL,
    item: WorkshopItem,
    to destinationDirectory: URL
  ) async throws -> URL {
    let projectURL = sourceDirectory.appending(path: "project.json")
    guard let data = try? Data(contentsOf: projectURL),
      let project = try? JSONDecoder().decode(WorkshopProject.self, from: data)
    else {
      throw VideoExtractorError.missingProject
    }
    guard project.type.caseInsensitiveCompare("video") == .orderedSame else {
      throw VideoExtractorError.unsupportedType(project.type)
    }

    let unresolvedVideoURL = sourceDirectory.appending(path: project.file)
    let unresolvedValues = try? unresolvedVideoURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard unresolvedValues?.isSymbolicLink != true else {
      throw VideoExtractorError.unsafePath
    }

    let resolvedRoot = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
    let videoURL =
      unresolvedVideoURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard videoURL.path.hasPrefix(resolvedRoot.path + "/") else {
      throw VideoExtractorError.unsafePath
    }

    let values = try? videoURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values?.isRegularFile == true,
      values?.isSymbolicLink != true,
      (values?.fileSize ?? 0) > 0
    else {
      throw VideoExtractorError.missingVideo
    }

    let asset = AVURLAsset(url: videoURL)
    guard (try? await asset.load(.isPlayable)) == true else {
      throw VideoExtractorError.unplayableVideo
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
    let title = sanitizedFilename(project.title.isEmpty ? item.title : project.title)
    let destinationURL =
      destinationDirectory
      .appending(path: "\(title) [\(item.id)].\(ext)")
    let temporaryURL =
      destinationDirectory
      .appending(path: ".\(item.id)-\(UUID().uuidString).partial")

    try fileManager.copyItem(at: videoURL, to: temporaryURL)
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      }
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
    return destinationURL
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
