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
    case .notInstalled: "没有找到 SteamCMD。"
    case .notLoggedIn: "请先登录 Steam。"
    case .loginFailed(let detail): detail
    case .downloadFailed(let detail): detail
    case .contentNotFound: "SteamCMD 已结束，但没有找到下载内容。"
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
  private var pendingIDs: [String] = []
  private var queueTask: Task<Void, Never>?
  private var activeID: String?
  private var cancelledIDs: Set<String> = []

  private static let pathKey = "SteamCMDPath"
  private static let usernameKey = "SteamLastUsername"
  private static let libraryKey = "WallpaperLibraryDirectory"

  init() {
    records = Self.loadRecords()
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

  func record(for workshopID: String) -> DownloadRecord? {
    records.first { $0.id == workshopID }
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
      pathError = "所选文件不存在。"
      return
    }
    if !fileManager.isExecutableFile(atPath: path) {
      try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
    guard fileManager.isExecutableFile(atPath: path) else {
      pathError = "所选文件不可执行。"
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

    var arguments = ["+login", username, password]
    if !guardCode.isEmpty {
      arguments.append(guardCode)
    }
    arguments.append("+quit")

    do {
      let result = try await processRunner.run(
        executableURL: URL(fileURLWithPath: steamCMDPath),
        arguments: arguments,
        currentDirectoryURL: URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent()
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
        throw SteamCMDServiceError.loginFailed("缓存会话已失效，请使用密码重新登录。")
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
        detail: "等待 SteamCMD",
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
      $0.detail = "任务已取消"
    }
  }

  func removeRecord(_ id: String) {
    guard activeID != id else { return }
    pendingIDs.removeAll { $0 == id }
    records.removeAll { $0.id == id }
    persistRecords()
  }

  func clearFinishedRecords() {
    records.removeAll { [.completed, .failed, .cancelled].contains($0.phase) }
    persistRecords()
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
    updateRecord(id) {
      $0.phase = .downloading
      $0.detail = "SteamCMD 正在下载并校验"
    }

    do {
      let result = try await processRunner.run(
        executableURL: URL(fileURLWithPath: steamCMDPath),
        arguments: [
          "+login", username,
          "+workshop_download_item", String(WorkshopAPIClient.wallpaperEngineAppID), id, "validate",
          "+quit",
        ],
        currentDirectoryURL: URL(fileURLWithPath: steamCMDPath).deletingLastPathComponent()
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
        $0.detail = "正在读取 project.json"
      }
      let destination = try await extractor.extract(
        from: sourceDirectory,
        item: item,
        to: libraryDirectory
      )
      try? FileManager.default.removeItem(at: sourceDirectory)
      updateRecord(id) {
        $0.phase = .completed
        $0.detail = destination.lastPathComponent
        $0.localPath = destination.path
        $0.completedAt = Date()
      }
    } catch {
      if cancelledIDs.remove(id) != nil { return }
      updateRecord(id) {
        $0.phase = .failed
        $0.detail = error.localizedDescription
      }
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

  private func updateRecord(_ id: String, update: (inout DownloadRecord) -> Void) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    update(&records[index])
    persistRecords()
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
        restored.detail = "应用上次退出时任务尚未完成"
      }
      return restored
    }
  }

  private static var recordsURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appending(path: "Wallpaper Browser/downloads.json")
  }

  private static func loginSucceeded(_ result: ProcessResult) -> Bool {
    result.output.contains("Logged in OK")
      || (result.terminationStatus == 0 && result.output.contains("OK"))
  }

  private static func loginFailureMessage(from output: String) -> String {
    if output.localizedCaseInsensitiveContains("Steam Guard")
      || output.localizedCaseInsensitiveContains("Two-factor")
    {
      return "需要 Steam Guard 验证码。"
    }
    if output.localizedCaseInsensitiveContains("Invalid Password") {
      return "Steam 用户名或密码错误。"
    }
    return "Steam 登录失败，请检查账户信息后重试。"
  }

  private static func downloadFailureMessage(from result: ProcessResult) -> String {
    let errorLine = result.output
      .components(separatedBy: .newlines)
      .first { line in
        line.localizedCaseInsensitiveContains("ERROR")
          || line.localizedCaseInsensitiveContains("FAILED")
      }
    return errorLine ?? "SteamCMD 下载失败（退出码 \(result.terminationStatus)）。"
  }
}
