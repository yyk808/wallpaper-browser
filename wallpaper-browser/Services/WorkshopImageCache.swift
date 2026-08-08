import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class WorkshopImageCache: ObservableObject {
  static let shared = WorkshopImageCache()

  @Published private(set) var diskUsageBytes: Int64 = 0
  @Published private(set) var maximumDiskUsageBytes: Int64

  private let memoryCache = NSCache<NSURL, NSImage>()
  private let diskCache: WorkshopImageDiskCache

  private static let maximumSizeKey = "WorkshopPreviewCacheMaximumSizeMB"
  private static let defaultMaximumSizeMB = 512
  private static let minimumMaximumSizeMB = 64
  private static let maximumMaximumSizeMB = 4_096

  private init() {
    let configuredSize = UserDefaults.standard.integer(forKey: Self.maximumSizeKey)
    let maximumSizeMB = configuredSize > 0 ? configuredSize : Self.defaultMaximumSizeMB
    maximumDiskUsageBytes = Int64(maximumSizeMB) * 1_024 * 1_024

    let directoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "Wallpaper Browser/Workshop Previews", directoryHint: .isDirectory)
    diskCache = WorkshopImageDiskCache(directoryURL: directoryURL)

    configureMemoryCache()
    Task { [weak self, diskCache, maximumDiskUsageBytes] in
      let usage = await diskCache.prepare(maximumSizeBytes: maximumDiskUsageBytes)
      self?.diskUsageBytes = usage
    }
  }

  var maximumSizeMegabytes: Int {
    Int(maximumDiskUsageBytes / 1_024 / 1_024)
  }

  func image(for url: URL) async -> NSImage? {
    if let image = memoryCache.object(forKey: url as NSURL) {
      return image
    }

    guard let data = await diskCache.data(for: url), !Task.isCancelled,
      let decodedImage = await Self.decode(data)
    else { return nil }

    memoryCache.setObject(
      decodedImage.image,
      forKey: url as NSURL,
      cost: decodedImage.memoryCost
    )
    return decodedImage.image
  }

  func image(from data: Data, for url: URL) async -> NSImage? {
    guard !Task.isCancelled, let decodedImage = await Self.decode(data) else { return nil }
    memoryCache.setObject(
      decodedImage.image,
      forKey: url as NSURL,
      cost: decodedImage.memoryCost
    )
    insert(data, for: url)
    return decodedImage.image
  }

  func setMaximumSize(megabytes: Int) {
    let clamped = min(
      max(megabytes, Self.minimumMaximumSizeMB),
      Self.maximumMaximumSizeMB
    )
    UserDefaults.standard.set(clamped, forKey: Self.maximumSizeKey)
    maximumDiskUsageBytes = Int64(clamped) * 1_024 * 1_024
    configureMemoryCache()

    let maximumSizeBytes = maximumDiskUsageBytes
    Task { [weak self, diskCache] in
      let usage = await diskCache.setMaximumSize(maximumSizeBytes)
      self?.diskUsageBytes = usage
    }
  }

  func clear() {
    memoryCache.removeAllObjects()
    diskUsageBytes = 0
    Task { [weak self, diskCache] in
      let usage = await diskCache.clear()
      self?.diskUsageBytes = usage
    }
  }

  func refreshDiskUsage() {
    Task { [weak self, diskCache] in
      let usage = await diskCache.refreshDiskUsage()
      self?.diskUsageBytes = usage
    }
  }

  private func insert(_ data: Data, for url: URL) {
    let maximumSizeBytes = maximumDiskUsageBytes
    Task { [weak self, diskCache] in
      let usage = await diskCache.insert(
        data,
        for: url,
        maximumSizeBytes: maximumSizeBytes
      )
      self?.diskUsageBytes = usage
    }
  }

  private func configureMemoryCache() {
    memoryCache.countLimit = 160
    memoryCache.totalCostLimit = Int(min(maximumDiskUsageBytes, 128 * 1_024 * 1_024))
  }

  nonisolated private static func decode(_ data: Data) async -> DecodedImage? {
    await Task.detached(priority: .userInitiated) {
      guard let image = NSImage(data: data) else { return nil }
      return DecodedImage(
        image: image,
        memoryCost: decodedMemoryCost(for: image, fallback: data.count)
      )
    }.value
  }

  nonisolated private static func decodedMemoryCost(for image: NSImage, fallback: Int) -> Int {
    let largestRepresentationCost = image.representations.reduce(0) { currentCost, representation in
      let pixelsWide = max(representation.pixelsWide, 1)
      let pixelsHigh = max(representation.pixelsHigh, 1)
      let frameCount: Int
      if let bitmap = representation as? NSBitmapImageRep {
        frameCount = (bitmap.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 1
      } else {
        frameCount = 1
      }
      return max(currentCost, pixelsWide * pixelsHigh * 4 * max(frameCount, 1))
    }
    return max(largestRepresentationCost, fallback)
  }
}

private struct DecodedImage: @unchecked Sendable {
  let image: NSImage
  let memoryCost: Int
}

private final class WorkshopImageDiskCache: @unchecked Sendable {
  private let directoryURL: URL
  private let queue = DispatchQueue(label: "neon.wallpaper-browser.preview-cache", qos: .utility)
  private var cachedFiles: [URL: CachedFile] = [:]
  private var diskUsageBytes: Int64?

  init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  func prepare(maximumSizeBytes: Int64) async -> Int64 {
    await perform {
      self.loadIndexIfNeeded()
      self.trimIfNeeded(maximumSizeBytes: maximumSizeBytes, usesHysteresis: false)
      return self.diskUsageBytes ?? 0
    }
  }

  func data(for url: URL) async -> Data? {
    await perform {
      self.loadIndexIfNeeded()
      let fileURL = self.cacheFileURL(for: url)
      guard let data = try? Data(contentsOf: fileURL) else {
        if let removedFile = self.cachedFiles.removeValue(forKey: fileURL) {
          self.diskUsageBytes = max(0, (self.diskUsageBytes ?? 0) - removedFile.size)
        }
        return nil
      }

      let modifiedAt = Date()
      try? FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: fileURL.path
      )
      self.cachedFiles[fileURL] = CachedFile(
        url: fileURL,
        size: Int64(data.count),
        modifiedAt: modifiedAt
      )
      return data
    }
  }

  func insert(_ data: Data, for url: URL, maximumSizeBytes: Int64) async -> Int64 {
    await perform {
      self.loadIndexIfNeeded()
      let fileURL = self.cacheFileURL(for: url)
      let previousSize = self.cachedFiles[fileURL]?.size ?? 0
      do {
        try FileManager.default.createDirectory(
          at: self.directoryURL,
          withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        let modifiedAt = Date()
        let size = Int64(data.count)
        self.cachedFiles[fileURL] = CachedFile(
          url: fileURL,
          size: size,
          modifiedAt: modifiedAt
        )
        self.diskUsageBytes = max(0, (self.diskUsageBytes ?? 0) - previousSize + size)
        self.trimIfNeeded(maximumSizeBytes: maximumSizeBytes, usesHysteresis: true)
      } catch {
        self.rebuildIndex()
      }
      return self.diskUsageBytes ?? 0
    }
  }

  func setMaximumSize(_ maximumSizeBytes: Int64) async -> Int64 {
    await perform {
      self.loadIndexIfNeeded()
      self.trimIfNeeded(maximumSizeBytes: maximumSizeBytes, usesHysteresis: false)
      return self.diskUsageBytes ?? 0
    }
  }

  func clear() async -> Int64 {
    await perform {
      try? FileManager.default.removeItem(at: self.directoryURL)
      try? FileManager.default.createDirectory(
        at: self.directoryURL,
        withIntermediateDirectories: true
      )
      self.cachedFiles = [:]
      self.diskUsageBytes = 0
      return 0
    }
  }

  func refreshDiskUsage() async -> Int64 {
    await perform {
      self.rebuildIndex()
      return self.diskUsageBytes ?? 0
    }
  }

  private func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: operation())
      }
    }
  }

  private func loadIndexIfNeeded() {
    guard diskUsageBytes == nil else { return }
    rebuildIndex()
  }

  private func rebuildIndex() {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )) ?? []

    cachedFiles = Dictionary(
      uniqueKeysWithValues: urls.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true
        else { return nil }
        let file = CachedFile(
          url: url,
          size: Int64(values.fileSize ?? 0),
          modifiedAt: values.contentModificationDate ?? .distantPast
        )
        return (url, file)
      }
    )
    diskUsageBytes = cachedFiles.values.reduce(0) { $0 + $1.size }
  }

  private func trimIfNeeded(maximumSizeBytes: Int64, usesHysteresis: Bool) {
    guard (diskUsageBytes ?? 0) > maximumSizeBytes else { return }
    let targetSize = usesHysteresis ? maximumSizeBytes * 9 / 10 : maximumSizeBytes
    let filesByAge = cachedFiles.values.sorted { $0.modifiedAt < $1.modifiedAt }

    for file in filesByAge where (diskUsageBytes ?? 0) > targetSize {
      do {
        try FileManager.default.removeItem(at: file.url)
        cachedFiles.removeValue(forKey: file.url)
        diskUsageBytes = max(0, (diskUsageBytes ?? 0) - file.size)
      } catch {
        continue
      }
    }
  }

  private func cacheFileURL(for url: URL) -> URL {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let filename = digest.map { String(format: "%02x", $0) }.joined()
    return directoryURL.appending(path: filename)
  }
}

private struct CachedFile {
  let url: URL
  let size: Int64
  let modifiedAt: Date
}
