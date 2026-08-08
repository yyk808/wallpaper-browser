import Combine
import Foundation

enum SteamCMDServiceError: LocalizedError {
  case notInstalled
  case notLoggedIn
  case loginFailed(String)
  case downloadFailed(String)
  case contentNotFound

  var errorDescription: String? {
    switch self {
    case .notInstalled: "steamcmd.error.notInstalled"
    case .notLoggedIn: "steamcmd.error.notSignedIn"
    case .loginFailed(let detail): detail
    case .downloadFailed(let detail): detail
    case .contentNotFound: "steamcmd.error.contentNotFound"
    }
  }
}

@MainActor
final class SteamCMDService: ObservableObject {
  @Published private(set) var steamCMDPath: String?
  @Published private(set) var isLoggedIn = false
  @Published private(set) var username = ""
  @Published private(set) var isLoggingIn = false
  @Published private(set) var records: [DownloadRecord] = []
  @Published var loginError: String?
  @Published var pathError: String?

  private let processRunner = ProcessRunner()
  private let extractor = VideoExtractor()
  private let metadataStore = DownloadMetadataStore()
  private var pendingIDs: [String] = []
  private var queueTask: Task<Void, Never>?
  private var activeID: String?
  private var cancelledIDs: Set<String> = []
  private var progressTrackers: [String: DownloadProgressTracker] = [:]

  private static let pathKey = "SteamCMDPath"
  private static let usernameKey = "SteamLastUsername"
  private static let libraryKey = "WallpaperLibraryDirectory"

  init() {
    records = Self.loadRecords()
    metadataStore.mergeCompletedRecords(records)
    username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
    detectSteamCMD()
    if steamCMDPath != nil, !username.isEmpty {
      Task { [weak self] in
        await self?.loginWithCachedSession(username: self?.username ?? "")
      }
    }
  }

  deinit {
    processRunner.cancel()
  }

  var isInstalled: Bool { steamCMDPath != nil }

  var libraryDirectory: URL {
    if let stored = UserDefaults.standard.string(forKey: Self.libraryKey), !stored.isEmpty {
      return URL(fileURLWithPath: stored, isDirectory: true)
    }
    return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
      .appending(path: "Wallpaper Browser", directoryHint: .isDirectory)
  }

  var activeDownloadCount: Int {
    records.filter { [.queued, .downloading, .extracting].contains($0.phase) }.count
  }

  var downloadedMetadataCount: Int { metadataStore.count }

  func record(for workshopID: String) -> DownloadRecord? {
    records.first { $0.id == workshopID }
  }

  func hasDownloaded(_ workshopID: String) -> Bool {
    metadataStore.contains(workshopID)
  }

  func detectSteamCMD() {
    pathError = nil
    let fileManager = FileManager.default
    if let custom = UserDefaults.standard.string(forKey: Self.pathKey),
      fileManager.isExecutableFile(atPath: custom)
    {
      steamCMDPath = custom
      return
    }

    let home = fileManager.homeDirectoryForCurrentUser.path
    let candidates = [
      "/opt/homebrew/bin/steamcmd",
      "/usr/local/bin/steamcmd",
      "/usr/bin/steamcmd",
      "\(home)/Library/Application Support/Steam/steamcmd",
      "\(home)/Library/Application Support/Steam/steamcmd/steamcmd",
      "\(home)/Library/Application Support/Steam/steamcmd.sh",
      "\(home)/steamcmd/steamcmd.sh",
      "\(home)/steamcmd/steamcmd",
      "\(home)/Downloads/steamcmd/steamcmd.sh",
      "\(home)/Downloads/steamcmd/steamcmd",
      "/Applications/steamcmd/steamcmd.sh",
      "/Applications/steamcmd/steamcmd",
    ]
    steamCMDPath = candidates.first(where: fileManager.isExecutableFile(atPath:))
  }

  func setCustomPath(_ path: String) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else {
      pathError = "steamcmd.error.fileMissing"
      return
    }
    if !fileManager.isExecutableFile(atPath: path) {
      try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
    guard fileManager.isExecutableFile(atPath: path) else {
      pathError = "steamcmd.error.notExecutable"
      return
    }
    UserDefaults.standard.set(path, forKey: Self.pathKey)
    steamCMDPath = path
    pathError = nil
  }

  func setLibraryDirectory(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: Self.libraryKey)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    objectWillChange.send()
  }

  func login(username: String, password: String, guardCode: String) async {
    guard let steamCMDPath else {
      loginError = SteamCMDServiceError.notInstalled.localizedDescription
      return
    }
    guard !username.isEmpty, !password.isEmpty else { return }

    isLoggingIn = true
    loginError = nil
    defer { isLoggingIn = false }

    var loginInput = password + "\n"
    if !guardCode.isEmpty {
      loginInput += guardCode + "\n"
    }

    do {
      let result = try await processRunner.run(
        executableURL: URL(fileURLWithPath: steamCMDPath),
        arguments: ["+login", username, "+quit"],
        currentDirectoryURL: URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent(),
        standardInput: loginInput
      )
      guard Self.loginSucceeded(result) else {
        throw SteamCMDServiceError.loginFailed(Self.loginFailureMessage(from: result.output))
      }
      completeLogin(username: username)
    } catch {
      loginError = error.localizedDescription
      isLoggedIn = false
    }
  }

  func loginWithCachedSession(username: String) async {
    guard let steamCMDPath, !username.isEmpty else { return }
    isLoggingIn = true
    loginError = nil
    defer { isLoggingIn = false }

    do {
      let result = try await processRunner.run(
        executableURL: URL(fileURLWithPath: steamCMDPath),
        arguments: ["+login", username, "+quit"],
        currentDirectoryURL: URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent()
      )
      guard Self.loginSucceeded(result) else {
        throw SteamCMDServiceError.loginFailed("steam.error.cachedSessionExpired")
      }
      completeLogin(username: username)
    } catch {
      loginError = error.localizedDescription
      isLoggedIn = false
    }
  }

  func logout() {
    isLoggedIn = false
    loginError = nil
  }

  func enqueue(_ item: WorkshopItem) {
    guard isInstalled, isLoggedIn else { return }
    if let record = record(for: item.id),
      record.phase == .completed,
      let url = record.localURL,
      FileManager.default.fileExists(atPath: url.path)
    {
      return
    }

    upsertRecord(
      DownloadRecord(
        id: item.id,
        item: item,
        phase: .queued,
        detail: "download.detail.waitingForSteamCMD",
        localPath: nil,
        createdAt: Date(),
        completedAt: nil
      )
    )
    if !pendingIDs.contains(item.id), activeID != item.id {
      pendingIDs.append(item.id)
    }
    startQueueIfNeeded()
  }

  func retry(_ id: String) {
    guard let item = record(for: id)?.item else { return }
    enqueue(item)
  }

  func cancel(_ id: String) {
    if activeID == id {
      cancelledIDs.insert(id)
      processRunner.cancel()
    } else {
      pendingIDs.removeAll { $0 == id }
    }
    updateRecord(id) {
      $0.phase = .cancelled
      $0.detail = "download.detail.cancelled"
      $0.bytesPerSecond = nil
    }
  }

  @discardableResult
  func moveRecordsToTrash(_ ids: Set<String>) -> String? {
    let fileManager = FileManager.default
    var removedIDs: Set<String> = []
    var errors: [String] = []

    for record in records where ids.contains(record.id) {
      guard ![.queued, .downloading, .extracting].contains(record.phase) else {
        errors.append("downloads.error.taskRunning|\(record.item.title)")
        continue
      }

      if let url = record.localURL, fileManager.fileExists(atPath: url.path) {
        do {
          try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
          errors.append("\(record.item.title)：\(error.localizedDescription)")
          continue
        }
      }
      removedIDs.insert(record.id)
    }

    if !removedIDs.isEmpty {
      for id in removedIDs {
        metadataStore.markLocalFileRemoved(workshopID: id)
      }
      pendingIDs.removeAll { removedIDs.contains($0) }
      records.removeAll { removedIDs.contains($0.id) }
      persistRecords()
    }
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func completeLogin(username: String) {
    self.username = username
    isLoggedIn = true
    loginError = nil
    UserDefaults.standard.set(username, forKey: Self.usernameKey)
    startQueueIfNeeded()
  }

  private func startQueueIfNeeded() {
    guard queueTask == nil, !pendingIDs.isEmpty else { return }
    queueTask = Task { [weak self] in
      await self?.drainQueue()
    }
  }

  private func drainQueue() async {
    while !pendingIDs.isEmpty {
      guard isInstalled, isLoggedIn else { break }
      let id = pendingIDs.removeFirst()
      activeID = id
      await performDownload(id: id)
      activeID = nil
    }
    queueTask = nil
  }

  private func performDownload(id: String) async {
    guard let steamCMDPath, let item = record(for: id)?.item else { return }
    progressTrackers[id] = DownloadProgressTracker()
    defer { progressTrackers.removeValue(forKey: id) }
    updateRecord(id) {
      $0.phase = .downloading
      $0.detail = "download.detail.steamDownloading"
      $0.progress = nil
      $0.bytesPerSecond = nil
    }

    do {
      let result = try await processRunner.run(
        executableURL: URL(fileURLWithPath: steamCMDPath),
        arguments: [
          "+login", username,
          "+workshop_download_item", String(WorkshopAPIClient.wallpaperEngineAppID), id, "validate",
          "+quit",
        ],
        currentDirectoryURL: URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent(),
        onOutput: { [weak self] output in
          Task { @MainActor [weak self] in
            self?.handleDownloadOutput(output, for: id)
          }
        }
      )
      if cancelledIDs.remove(id) != nil { return }
      guard result.terminationStatus == 0,
        !result.output.localizedCaseInsensitiveContains("FAILED"),
        !result.output.localizedCaseInsensitiveContains("ERROR")
      else {
        throw SteamCMDServiceError.downloadFailed(Self.downloadFailureMessage(from: result))
      }
      guard let sourceDirectory = findDownloadedItem(id: id, steamCMDPath: steamCMDPath) else {
        throw SteamCMDServiceError.contentNotFound
      }

      updateRecord(id) {
        $0.phase = .extracting
        $0.detail = "download.detail.readingProject"
        $0.progress = 1
        $0.bytesPerSecond = nil
      }
      let destination = try await extractor.extract(
        from: sourceDirectory,
        item: item,
        to: libraryDirectory
      )
      try? FileManager.default.removeItem(at: sourceDirectory)
      let completedAt = Date()
      updateRecord(id) {
        $0.phase = .completed
        $0.detail = destination.lastPathComponent
        $0.localPath = destination.path
        $0.completedAt = completedAt
        $0.progress = 1
        $0.bytesPerSecond = nil
      }
      metadataStore.recordDownload(
        workshopID: id,
        downloadedAt: completedAt,
        localPath: destination.path
      )
    } catch {
      if cancelledIDs.remove(id) != nil { return }
      updateRecord(id) {
        $0.phase = .failed
        $0.detail = error.localizedDescription
        $0.bytesPerSecond = nil
      }
    }
  }

  private func handleDownloadOutput(_ output: String, for id: String) {
    guard
      let record = record(for: id),
      record.phase == .downloading,
      var tracker = progressTrackers[id]
    else { return }

    tracker.recentOutput.append(output)
    tracker.recentOutput = String(tracker.recentOutput.suffix(8_192))

    let now = Date()
    if let lastPublishDate = tracker.lastPublishDate,
      now.timeIntervalSince(lastPublishDate) < 0.25
    {
      progressTrackers[id] = tracker
      return
    }
    tracker.lastPublishDate = now

    let parsedProgress = Self.parseProgress(from: tracker.recentOutput)
    let progress = max(record.progress ?? 0, parsedProgress?.fraction ?? 0)
    let downloadedBytes =
      parsedProgress?.downloadedBytes
      ?? parsedProgress?.totalBytes.map { Int64(Double($0) * progress) }
      ?? (record.item.fileSize > 0 && progress > 0
        ? Int64(Double(record.item.fileSize) * progress) : nil)

    if let downloadedBytes {
      if let previousBytes = tracker.lastDownloadedBytes,
        let previousDate = tracker.lastSampleDate,
        downloadedBytes > previousBytes
      {
        let elapsed = now.timeIntervalSince(previousDate)
        if elapsed >= 0.2 {
          let currentSpeed = Double(downloadedBytes - previousBytes) / elapsed
          tracker.smoothedBytesPerSecond =
            tracker.smoothedBytesPerSecond.map { $0 * 0.65 + currentSpeed * 0.35 }
            ?? currentSpeed
          tracker.lastDownloadedBytes = downloadedBytes
          tracker.lastSampleDate = now
        }
      } else if tracker.lastDownloadedBytes == nil {
        tracker.lastDownloadedBytes = downloadedBytes
        tracker.lastSampleDate = now
      }
    }

    let status = Self.downloadStatus(from: output)
    progressTrackers[id] = tracker
    var updatedRecord = record
    if parsedProgress != nil {
      updatedRecord.progress = min(progress, 1)
    }
    if let status {
      updatedRecord.detail = status.detail
      updatedRecord.bytesPerSecond =
        status.isTransferring ? tracker.smoothedBytesPerSecond : nil
    } else {
      updatedRecord.bytesPerSecond = tracker.smoothedBytesPerSecond
    }
    guard updatedRecord != record else { return }
    updateRecord(id, persist: false) {
      $0 = updatedRecord
    }
  }

  private func findDownloadedItem(id: String, steamCMDPath: String) -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let executableDirectory = URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent()
    let roots = [
      executableDirectory.appending(path: "steamapps"),
      home.appending(path: "Library/Application Support/Steam/steamapps"),
      home.appending(path: "Library/Application Support/Steam/steamcmd/steamapps"),
      home.appending(path: "Steam/steamapps"),
    ]
    return
      roots
      .map {
        $0.appending(path: "workshop/content/\(WorkshopAPIClient.wallpaperEngineAppID)/\(id)")
      }
      .first { fileManager.fileExists(atPath: $0.path) }
  }

  private func upsertRecord(_ record: DownloadRecord) {
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      records[index] = record
    } else {
      records.insert(record, at: 0)
    }
    persistRecords()
  }

  private func updateRecord(
    _ id: String,
    persist: Bool = true,
    update: (inout DownloadRecord) -> Void
  ) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    update(&records[index])
    if persist {
      persistRecords()
    }
  }

  private func persistRecords() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    let url = Self.recordsURL
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
  }

  private static func loadRecords() -> [DownloadRecord] {
    guard let data = try? Data(contentsOf: recordsURL),
      let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
    else { return [] }
    return records.map { record in
      var restored = record
      if [.queued, .downloading, .extracting].contains(restored.phase) {
        restored.phase = .failed
        restored.detail = "download.detail.interrupted"
        restored.progress = nil
        restored.bytesPerSecond = nil
      }
      return restored
    }
  }

  private static var recordsURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appending(path: "Wallpaper Browser/downloads.json")
  }

  private static let progressExpression = try! NSRegularExpression(
    pattern: #"progress:\s*([\d.]+)(?:\s*\(([\d,]+)\s*/\s*([\d,]+)\))?"#,
    options: [.caseInsensitive]
  )

  private static func parseProgress(from output: String) -> ParsedDownloadProgress? {
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = progressExpression.matches(in: output, range: range).last,
      let percentageString = capture(1, from: match, in: output),
      let percentage = Double(percentageString)
    else { return nil }

    let downloadedBytes = capture(2, from: match, in: output)
      .map { $0.replacingOccurrences(of: ",", with: "") }
      .flatMap(Int64.init)
    let totalBytes = capture(3, from: match, in: output)
      .map { $0.replacingOccurrences(of: ",", with: "") }
      .flatMap(Int64.init)
    return ParsedDownloadProgress(
      fraction: min(max(percentage / 100, 0), 1),
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes
    )
  }

  private static func capture(
    _ index: Int,
    from match: NSTextCheckingResult,
    in output: String
  ) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound, let swiftRange = Range(range, in: output) else {
      return nil
    }
    return String(output[swiftRange])
  }

  private static func downloadStatus(from output: String) -> DownloadOutputStatus? {
    let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
    for line in lines.reversed() {
      let value = line.lowercased()
      if value.contains("success") && value.contains("download") {
        return DownloadOutputStatus(detail: "download.detail.preparingFiles", isTransferring: false)
      }
      if value.contains("validat") || value.contains("update state (0x5)") {
        return DownloadOutputStatus(detail: "download.detail.verifyingFiles", isTransferring: false)
      }
      if value.contains("committing") || value.contains("update state (0x101)") {
        return DownloadOutputStatus(detail: "download.detail.submitting", isTransferring: false)
      }
      if value.contains("downloading item") || value.contains("workshop_download_item") {
        return DownloadOutputStatus(detail: "download.detail.requestingWorkshop", isTransferring: false)
      }
      if value.contains("progress:") || value.contains("downloading") {
        return DownloadOutputStatus(detail: "download.detail.downloading", isTransferring: true)
      }
      if value.contains("logging in") || value.contains("logged in") {
        return DownloadOutputStatus(detail: "download.detail.verifyingSession", isTransferring: false)
      }
    }
    return nil
  }

  private static func loginSucceeded(_ result: ProcessResult) -> Bool {
    result.output.contains("Logged in OK")
      || (result.terminationStatus == 0 && result.output.contains("OK"))
  }

  private static func loginFailureMessage(from output: String) -> String {
    if output.localizedCaseInsensitiveContains("Steam Guard")
      || output.localizedCaseInsensitiveContains("Two-factor")
    {
      return "steam.error.guardRequired"
    }
    if output.localizedCaseInsensitiveContains("Invalid Password") {
      return "steam.error.invalidCredentials"
    }
    return "steam.error.loginFailed"
  }

  private static func downloadFailureMessage(from result: ProcessResult) -> String {
    let errorLine = result.output
      .components(separatedBy: .newlines)
      .first { line in
        line.localizedCaseInsensitiveContains("ERROR")
          || line.localizedCaseInsensitiveContains("FAILED")
      }
    return errorLine ?? "steamcmd.error.downloadFailed|\(result.terminationStatus)"
  }
}

private struct DownloadProgressTracker {
  var recentOutput = ""
  var lastDownloadedBytes: Int64?
  var lastSampleDate: Date?
  var smoothedBytesPerSecond: Double?
  var lastPublishDate: Date?
}

private struct ParsedDownloadProgress {
  let fraction: Double
  let downloadedBytes: Int64?
  let totalBytes: Int64?
}

private struct DownloadOutputStatus {
  let detail: String
  let isTransferring: Bool
}
