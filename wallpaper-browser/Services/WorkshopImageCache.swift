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
  private var inFlightLoads: [ImageLoadKey: InFlightImageLoad] = [:]

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

  func memoryImage(for url: URL) -> NSImage? {
    memoryCache.object(forKey: url as NSURL)
  }

  func loadImage(for url: URL, bypassCache: Bool) async -> NSImage? {
    guard !Task.isCancelled else { return nil }

    let key = ImageLoadKey(url: url, bypassCache: bypassCache)
    if let inFlightLoad = inFlightLoads[key] {
      return await waitForLoad(inFlightLoad, key: key)
    }

    if bypassCache {
      let cachedLoadKey = ImageLoadKey(url: url, bypassCache: false)
      cancelLoad(for: cachedLoadKey)
    }

    if !bypassCache, let image = memoryImage(for: url) {
      return image
    }

    let id = UUID()
    let task = makeLoadTask(for: url, bypassCache: bypassCache, key: key, id: id)
    let inFlightLoad = InFlightImageLoad(id: id, task: task)
    inFlightLoads[key] = inFlightLoad

    return await waitForLoad(inFlightLoad, key: key)
  }

  private func makeLoadTask(
    for url: URL,
    bypassCache: Bool,
    key: ImageLoadKey,
    id: UUID
  ) -> Task<NSImage?, Never> {
    Task { @MainActor [weak self] in
      guard let self else { return nil }

      let image: NSImage?
      if !bypassCache, let cachedImage = await self.cachedImage(for: url) {
        image = cachedImage
      } else if Task.isCancelled {
        image = nil
      } else {
        var request = URLRequest(url: url)
        request.cachePolicy = bypassCache
          ? .reloadIgnoringLocalCacheData
          : .useProtocolCachePolicy

        do {
          let (data, response) = try await URLSession.shared.data(for: request)
          guard !Task.isCancelled,
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
          else {
            image = nil
            self.completeLoad(key: key, id: id, result: nil)
            return nil
          }
          image = await self.cacheImage(from: data, for: url)
        } catch {
          image = nil
        }
      }

      self.completeLoad(key: key, id: id, result: image)
      return image
    }
  }

  private func waitForLoad(_ load: InFlightImageLoad, key: ImageLoadKey) async -> NSImage? {
    let waiterID = UUID()
    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
        guard !Task.isCancelled else {
          if load.waiters.isEmpty, let currentLoad = inFlightLoads[key], currentLoad === load {
            cancelLoad(for: key, expectedID: load.id)
          }
          continuation.resume(returning: nil)
          return
        }

        guard !load.isFinished else {
          continuation.resume(returning: load.result)
          return
        }

        guard let currentLoad = inFlightLoads[key], currentLoad === load else {
          continuation.resume(returning: nil)
          return
        }

        load.waiters[waiterID] = continuation
      }
    }, onCancel: { [weak self] in
      Task { @MainActor [weak self] in
        self?.cancelWaiter(key: key, loadID: load.id, waiterID: waiterID)
      }
    })
  }

  private func cancelWaiter(key: ImageLoadKey, loadID: UUID, waiterID: UUID) {
    guard let load = inFlightLoads[key], load.id == loadID,
      let continuation = load.waiters.removeValue(forKey: waiterID)
    else { return }

    continuation.resume(returning: nil)
    if load.waiters.isEmpty {
      cancelLoad(for: key, expectedID: loadID)
    }
  }

  private func cancelLoad(for key: ImageLoadKey) {
    guard let load = inFlightLoads[key] else { return }
    cancelLoad(for: key, expectedID: load.id)
  }

  private func cancelLoad(for key: ImageLoadKey, expectedID: UUID) {
    guard let load = inFlightLoads[key], load.id == expectedID else { return }

    inFlightLoads.removeValue(forKey: key)
    load.isFinished = true
    load.result = nil
    load.task.cancel()

    let waiters = Array(load.waiters.values)
    load.waiters.removeAll()
    for continuation in waiters {
      continuation.resume(returning: nil)
    }
  }

  private func completeLoad(key: ImageLoadKey, id: UUID, result: NSImage?) {
    guard let load = inFlightLoads[key], load.id == id else { return }

    inFlightLoads.removeValue(forKey: key)
    load.isFinished = true
    load.result = result

    let waiters = Array(load.waiters.values)
    load.waiters.removeAll()
    for continuation in waiters {
      continuation.resume(returning: result)
    }
  }

  private func cachedImage(for url: URL) async -> NSImage? {
    if let image = memoryImage(for: url) {
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

  private func cacheImage(from data: Data, for url: URL) async -> NSImage? {
    guard !Task.isCancelled, let decodedImage = await Self.decode(data), !Task.isCancelled else {
      return nil
    }
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
    for key in Array(inFlightLoads.keys) {
      cancelLoad(for: key)
    }
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
    await WorkshopImageDecoder.shared.decode(data)
  }

  nonisolated fileprivate static func decodedMemoryCost(for image: NSImage, fallback: Int) -> Int {
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

private struct ImageLoadKey: Hashable {
  let url: URL
  let bypassCache: Bool
}

@MainActor
private final class InFlightImageLoad {
  let id: UUID
  let task: Task<NSImage?, Never>
  var isFinished = false
  var result: NSImage?
  var waiters: [UUID: CheckedContinuation<NSImage?, Never>] = [:]

  init(id: UUID, task: Task<NSImage?, Never>) {
    self.id = id
    self.task = task
  }
}

private actor WorkshopImageDecoder {
  static let shared = WorkshopImageDecoder()

  func decode(_ data: Data) -> DecodedImage? {
    autoreleasepool {
      guard let image = NSImage(data: data) else { return nil }
      return DecodedImage(
        image: image,
        memoryCost: WorkshopImageCache.decodedMemoryCost(for: image, fallback: data.count)
      )
    }
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
  private var metadataWriteDates: [URL: Date] = [:]
  private var diskUsageBytes: Int64?
  private static let metadataWriteInterval: TimeInterval = 60 * 60

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
      guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
        if let removedFile = self.cachedFiles.removeValue(forKey: fileURL) {
          self.diskUsageBytes = max(0, (self.diskUsageBytes ?? 0) - removedFile.size)
        }
        self.metadataWriteDates.removeValue(forKey: fileURL)
        return nil
      }

      let modifiedAt = Date()
      let lastMetadataWrite =
        self.metadataWriteDates[fileURL]
        ?? self.cachedFiles[fileURL]?.modifiedAt
        ?? .distantPast
      if modifiedAt.timeIntervalSince(lastMetadataWrite) >= Self.metadataWriteInterval {
        do {
          try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: fileURL.path
          )
          self.metadataWriteDates[fileURL] = modifiedAt
        } catch {
          // A cache hit should still succeed if updating its LRU metadata fails.
        }
      }
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
        self.metadataWriteDates[fileURL] = modifiedAt
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
      self.metadataWriteDates = [:]
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
    metadataWriteDates = cachedFiles.mapValues(\.modifiedAt)
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
        metadataWriteDates.removeValue(forKey: file.url)
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
