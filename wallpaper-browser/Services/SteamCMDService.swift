import Combine
import Dispatch
import Foundation

enum SteamCMDServiceError: LocalizedError {
  case notInstalled
  case notLoggedIn
  case loginFailed(String)
  case downloadFailed(String)
  case contentNotFound
  case installDownloadFailed(String)
  case installExtractFailed
  case installBinaryMissing

  var errorDescription: String? {
    switch self {
    case .notInstalled: "steamcmd.error.notInstalled"
    case .notLoggedIn: "steamcmd.error.notSignedIn"
    case .loginFailed(let detail): detail
    case .downloadFailed(let detail): detail
    case .contentNotFound: "steamcmd.error.contentNotFound"
    case .installDownloadFailed(let detail): "steamcmd.error.installDownloadFailed|\(detail)"
    case .installExtractFailed: "steamcmd.error.installExtractFailed"
    case .installBinaryMissing: "steamcmd.error.installBinaryMissing"
    }
  }
}

@MainActor
final class SteamCMDService: ObservableObject {
  @Published private(set) var steamCMDPath: String?
  @Published private(set) var isLoggedIn = false
  @Published private(set) var username = ""
  @Published private(set) var isLoggingIn = false
  @Published private(set) var isInstallingSteamCMD = false
  @Published private(set) var steamCMDInstallProgress = 0.0
  @Published private(set) var records: [DownloadRecord] = []
  @Published var loginError: String?
  @Published var pathError: String?
  @Published var steamCMDInstallError: String?

  private let processRunner = ProcessRunner()
  private let extractor = VideoExtractor()
  private let metadataStore = DownloadMetadataStore()
  private var pendingIDs: [String] = []
  private var queueTask: Task<Void, Never>?
  private var activeID: String?
  private var cancelledIDs: Set<String> = []
  private var progressTrackers: [String: DownloadProgressTracker] = [:]
  private var recordIndices: [String: Int] = [:]

  private static let pathKey = "SteamCMDPath"
  private static let usernameKey = "SteamLastUsername"
  private static let libraryKey = "WallpaperLibraryDirectory"
  private static let steamCMDArchiveURLString =
    "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"

  private static var managedSteamCMDDirectory: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appending(path: "Wallpaper Browser/steamcmd", directoryHint: .isDirectory)
  }

  init() {
    records = Self.loadRecords()
    rebuildRecordIndices()
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

  var isUsingManagedSteamCMD: Bool {
    guard let path = steamCMDPath else { return false }
    return path.hasPrefix(Self.managedSteamCMDDirectory.path)
  }

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
    guard let index = recordIndices[workshopID], records.indices.contains(index) else {
      return nil
    }
    return records[index]
  }

  func markVideoAsSystemPlayable(at url: URL) {
    guard let record = records.first(where: { $0.localURL?.path == url.path }),
      record.needsThirdPartyPlayer
    else { return }
    updateRecord(record.id) {
      $0.needsThirdPartyPlayer = false
    }
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

    let managedDirectory = Self.managedSteamCMDDirectory.path
    if let managedPath = ["\(managedDirectory)/steamcmd.sh", "\(managedDirectory)/steamcmd"]
      .first(where: fileManager.isExecutableFile(atPath:))
    {
      steamCMDPath = managedPath
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
        throw SteamCMDServiceError.loginFailed(Self.loginFailureMessage(from: result))
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

  func installSteamCMD() async {
    guard !isInstallingSteamCMD else { return }
    isInstallingSteamCMD = true
    steamCMDInstallError = nil
    steamCMDInstallProgress = 0
    defer { isInstallingSteamCMD = false }

    do {
      let directory = Self.managedSteamCMDDirectory
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      let archive = try await SteamCMDArchiveDownloader(
        progress: { @MainActor [weak self] fraction in
          self?.steamCMDInstallProgress = fraction
        }
      ).download(from: URL(string: Self.steamCMDArchiveURLString)!)
      steamCMDInstallProgress = 1

      let result: ProcessResult
      do {
        result = try await processRunner.run(
          executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
          arguments: ["-xzf", archive.path, "-C", directory.path]
        )
      } catch {
        throw SteamCMDServiceError.installExtractFailed
      }
      guard result.terminationStatus == 0 else {
        throw SteamCMDServiceError.installExtractFailed
      }

      guard let executable = Self.managedExecutable(in: directory) else {
        throw SteamCMDServiceError.installBinaryMissing
      }
      registerManagedSteamCMD(at: executable)
    } catch {
      steamCMDInstallError = error.localizedDescription
    }
  }

  private func registerManagedSteamCMD(at executable: URL) {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    UserDefaults.standard.set(executable.path, forKey: Self.pathKey)
    steamCMDPath = executable.path
    pathError = nil
  }

  private static func managedExecutable(in directory: URL) -> URL? {
    let fileManager = FileManager.default
    let executableNames = ["steamcmd.sh", "steamcmd"]
    let direct = executableNames
      .map { directory.appending(path: $0) }
      .first { fileManager.isExecutableFile(atPath: $0.path) }
    if direct != nil { return direct }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ) else { return nil }
    for entry in entries where entry.hasDirectoryPath {
      if let nested = executableNames
        .map({ entry.appending(path: $0) })
        .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
      {
        return nested
      }
    }
    return nil
  }

  func enqueue(_ item: WorkshopItem) {
    guard isInstalled, isLoggedIn, item.isVideo else { return }
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
      metadataStore.markLocalFilesRemoved(workshopIDs: removedIDs)
      pendingIDs.removeAll { removedIDs.contains($0) }
      records.removeAll { removedIDs.contains($0.id) }
      rebuildRecordIndices()
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
      let workshopSteamappsRoots = workshopSteamappsRoots(for: steamCMDPath)
      let logCheckpoint = WorkshopManifestStateRepair.checkpoint(in: workshopSteamappsRoots)
      var result = try await runWorkshopDownload(id: id, steamCMDPath: steamCMDPath)
      if cancelledIDs.remove(id) != nil { return }

      var extractionError: Error?
      do {
        if try await extractDownloadedVideo(
          id: id,
          item: item,
          steamappsRoots: workshopSteamappsRoots
        ) { return }
      } catch {
        extractionError = error
      }

      if !Self.downloadSucceeded(result),
        await WorkshopManifestStateRepair.repairMissingSource(
          in: workshopSteamappsRoots,
          after: logCheckpoint,
          requestedID: id
        ) != nil
      {
        updateRecord(id) {
          $0.phase = .downloading
          $0.detail = "download.detail.repairingWorkshopCache"
          $0.progress = nil
          $0.bytesPerSecond = nil
        }
        result = try await runWorkshopDownload(id: id, steamCMDPath: steamCMDPath)
        if cancelledIDs.remove(id) != nil { return }
        do {
          if try await extractDownloadedVideo(
            id: id,
            item: item,
            steamappsRoots: workshopSteamappsRoots
          ) { return }
        } catch {
          extractionError = error
        }
      }

      guard Self.downloadSucceeded(result) else {
        throw SteamCMDServiceError.downloadFailed(Self.downloadFailureMessage(from: result))
      }
      if let extractionError { throw extractionError }
      throw SteamCMDServiceError.contentNotFound
    } catch {
      if cancelledIDs.remove(id) != nil { return }
      updateRecord(id) {
        $0.phase = .failed
        $0.detail = error.localizedDescription
        $0.bytesPerSecond = nil
      }
    }
  }

  private func runWorkshopDownload(id: String, steamCMDPath: String) async throws -> ProcessResult {
    let outputCoalescer = DownloadOutputCoalescer { [weak self] output in
      self?.handleDownloadOutput(output, for: id)
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
        onOutput: { output in
          outputCoalescer.append(output)
        }
      )
      await outputCoalescer.finish()
      return result
    } catch {
      await outputCoalescer.finish()
      throw error
    }
  }

  private func extractDownloadedVideo(
    id: String,
    item: WorkshopItem,
    steamappsRoots: [URL]
  ) async throws -> Bool {
    guard let sourceDirectory = findDownloadedItem(id: id, in: steamappsRoots) else {
      return false
    }
    updateRecord(id) {
      $0.phase = .extracting
      $0.detail = "download.detail.findingVideo"
      $0.progress = 1
      $0.bytesPerSecond = nil
    }
    let extraction = try await extractor.extract(
      from: sourceDirectory,
      item: item,
      to: libraryDirectory
    )
    let completedAt = Date()
    updateRecord(id) {
      $0.phase = .completed
      $0.detail = extraction.url.lastPathComponent
      $0.localPath = extraction.url.path
      $0.completedAt = completedAt
      $0.progress = 1
      $0.bytesPerSecond = nil
      $0.needsThirdPartyPlayer = extraction.needsThirdPartyPlayer
    }
    metadataStore.recordDownload(
      workshopID: id,
      downloadedAt: completedAt,
      localPath: extraction.url.path
    )
    return true
  }

  private static func downloadSucceeded(_ result: ProcessResult) -> Bool {
    result.terminationStatus == 0 && !result.containsFailed && !result.containsError
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

    let status = Self.downloadStatus(from: tracker.recentOutput)
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

  private func findDownloadedItem(id: String, in steamappsRoots: [URL]) -> URL? {
    let fileManager = FileManager.default
    return
      steamappsRoots
      .map {
        $0.appending(path: "workshop/content/\(WorkshopAPIClient.wallpaperEngineAppID)/\(id)")
      }
      .first { fileManager.fileExists(atPath: $0.path) }
  }

  private func workshopSteamappsRoots(for steamCMDPath: String) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let executableDirectory = URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent()
    return [
      executableDirectory.appending(path: "steamapps"),
      home.appending(path: "Library/Application Support/Steam/steamapps"),
      home.appending(path: "Library/Application Support/Steam/steamcmd/steamapps"),
      home.appending(path: "Steam/steamapps"),
    ]
  }

  private func upsertRecord(_ record: DownloadRecord) {
    if let index = recordIndices[record.id] {
      records[index] = record
    } else {
      records.insert(record, at: 0)
      rebuildRecordIndices()
    }
    persistRecords()
  }

  private func updateRecord(
    _ id: String,
    persist: Bool = true,
    update: (inout DownloadRecord) -> Void
  ) {
    guard let index = recordIndices[id] else { return }
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

  private func rebuildRecordIndices() {
    recordIndices.removeAll(keepingCapacity: true)
    for (index, record) in records.enumerated() where recordIndices[record.id] == nil {
      recordIndices[record.id] = index
    }
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
    result.containsLoggedInOK
      || result.output.contains("Logged in OK")
      || (result.terminationStatus == 0 && (result.containsOK || result.output.contains("OK")))
  }

  private static func loginFailureMessage(from result: ProcessResult) -> String {
    if result.containsSteamGuard
      || result.containsTwoFactor
      || result.output.localizedCaseInsensitiveContains("Steam Guard")
      || result.output.localizedCaseInsensitiveContains("Two-factor")
    {
      return "steam.error.guardRequired"
    }
    if result.containsInvalidPassword
      || result.output.localizedCaseInsensitiveContains("Invalid Password")
    {
      return "steam.error.invalidCredentials"
    }
    return "steam.error.loginFailed"
  }

  private static func downloadFailureMessage(from result: ProcessResult) -> String {
    if let errorLine = result.errorLine, !errorLine.isEmpty {
      return errorLine
    }
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

private final class DownloadOutputCoalescer: @unchecked Sendable {
  private static let deliveryIntervalNanoseconds: UInt64 = 100_000_000
  private static let pendingOutputLimit = 128 * 1_024

  private let lock = NSLock()
  private let deliver: @MainActor @Sendable (String) -> Void
  private var pendingOutput = ""
  private var worker: Task<Void, Never>?
  private var isFinished = false

  init(deliver: @escaping @MainActor @Sendable (String) -> Void) {
    self.deliver = deliver
  }

  func append(_ output: String) {
    guard !output.isEmpty else { return }

    lock.lock()
    defer { lock.unlock() }
    guard !isFinished else { return }

    pendingOutput.append(output)
    if pendingOutput.utf8.count > Self.pendingOutputLimit {
      pendingOutput = String(pendingOutput.suffix(Self.pendingOutputLimit))
    }

    guard worker == nil else { return }
    worker = Task.detached(priority: .utility) { [self] in
      await self.runWorker()
    }
  }

  func finish() async {
    let worker = markFinished()
    await worker?.value
  }

  private func markFinished() -> Task<Void, Never>? {
    lock.lock()
    isFinished = true
    let worker = self.worker
    worker?.cancel()
    lock.unlock()
    return worker
  }

  private func runWorker() async {
    while true {
      do {
        try await Task.sleep(nanoseconds: Self.deliveryIntervalNanoseconds)
      } catch {
        // finish() cancels the sleep to force the final pending batch through now.
      }

      let (output, finished) = takePendingOutput()
      if let output {
        await deliver(output)
      }
      if finished {
        clearWorker()
        return
      }
    }
  }

  private func clearWorker() {
    lock.lock()
    worker = nil
    lock.unlock()
  }

  private func takePendingOutput() -> (String?, Bool) {
    lock.lock()
    defer { lock.unlock() }
    let output = pendingOutput.isEmpty ? nil : pendingOutput
    pendingOutput.removeAll(keepingCapacity: true)
    return (output, isFinished)
  }
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

private final class SteamCMDArchiveDownloader: NSObject, URLSessionDownloadDelegate {
  private let progressContinuation: AsyncStream<Double>.Continuation
  private let progressTask: Task<Void, Never>

  init(progress: @escaping @MainActor @Sendable (Double) -> Void) {
    let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream(
      of: Double.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.progressContinuation = progressContinuation
    self.progressTask = Task { @MainActor in
      var latestProgress = 0.0
      var lastDeliveredProgress: Double?
      var lastDeliveryDate: Date?

      for await fraction in progressStream {
        latestProgress = max(latestProgress, min(max(fraction, 0), 1))
        let now = Date()
        let isComplete = latestProgress >= 1
        let isThrottled = lastDeliveryDate.map {
          now.timeIntervalSince($0) < 0.1
        } ?? false
        guard isComplete || !isThrottled else { continue }
        guard lastDeliveredProgress != latestProgress else { continue }

        progress(latestProgress)
        lastDeliveredProgress = latestProgress
        lastDeliveryDate = now
      }

      // A successful download always yields 1.0 before closing the stream. Keep
      // this guard as the final delivery point if the stream was coalesced while
      // the main actor was busy.
      if latestProgress >= 1, lastDeliveredProgress != 1 {
        progress(1)
      }
    }
    super.init()
  }

  func download(from url: URL) async throws -> URL {
    let configuration = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    do {
      let (location, response) = try await session.download(for: URLRequest(url: url))
      guard let status = (response as? HTTPURLResponse)?.statusCode,
        (200..<300).contains(status)
      else {
        throw SteamCMDServiceError.installDownloadFailed(
          "HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))"
        )
      }

      progressContinuation.yield(1)
      progressContinuation.finish()
      await progressTask.value
      return location
    } catch {
      progressContinuation.finish()
      await progressTask.value
      throw error
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
    progressContinuation.yield(fraction)
  }
}
