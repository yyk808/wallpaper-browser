import Foundation

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  static var respond: (URLRequest) throws -> (Int, String) = { _ in (500, "") }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.respond(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure.failed(message) }
}

@main
struct WorkshopAPIChecks {
  static func main() async throws {
    if CommandLine.arguments.contains("--live") { try await live(); return }
    try check(WorkshopReference(text: " https://steamcommunity.com/sharedfiles/filedetails/?id=123&searchtext=x ") == .file("123"), "Workshop URL")
    try check(WorkshopReference(text: "123") == .file("123"), "numeric ID")
    try check(WorkshopReference(text: "https://steamcommunity.com/profiles/76561198000000000/myworkshopfiles/") == .creator("76561198000000000"), "creator URL")
    try check(WorkshopReference(text: "https://steamcommunity.com/id/creator/") == .vanity("creator"), "vanity URL")
    for value in ["0", "-1", "18446744073709551616", "https://steamcommunity.com.evil.test/sharedfiles/filedetails/?id=123", "file:///tmp/file", "https://steamcommunity.com/sharedfiles/filedetails/?id=foo"] {
      try check(WorkshopReference(text: value) == nil, "Reject invalid reference")
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config)
    let api = WorkshopAPIClient(apiKeyProvider: { "test-key" }, session: session)
    defer { session.invalidateAndCancel() }
    StubProtocol.respond = { request in
      if request.url!.path.contains("GetPlayerSummaries") { return (200, #"{"response":{"players":[]}}"#) }
      let input = try parameters(request)
      try check(input["includeadditionalpreviews"] as? Bool == true, "request additional previews")
      return (200, #"{"response":{"publishedfiledetails":[{"result":1,"publishedfileid":"123","consumer_appid":431960,"title":"Collection","file_type":2,"file_description":"Full description","file_size":"1024","time_created":100,"time_updated":200,"views":10,"favorited":3,"preview_url":"https://example.com/cover.jpg","children":[{"publishedfileid":"2","sortorder":2},{"publishedfileid":"1","sortorder":1}],"previews":[{"preview_type":0,"url":"https://example.com/second.jpg"},{"preview_type":1,"youtubevideoid":"abc"},{"preview_type":1,"external_url":"file:///tmp/a"}]}]}}"#)
    }
    let detail = try await api.fetchDetails(id: "123")
    try check(detail.item.isCollection && !detail.item.isVideo, "collection cannot download as video")
    try check(detail.description == "Full description" && detail.item.summary == detail.description, "full description fallback")
    try check(detail.childIDs == ["1", "2"], "respect collection order")
    try check(detail.previews.count == 3 && detail.previews.last?.kind == .videoLink, "preview types and URL filtering")
    try check(detail.updatedAt == Date(timeIntervalSince1970: 200), "timestamps")
    // Old download metadata must remain readable after adding fileType.
    let legacy = #"{"id":"9","title":"Old","summary":"","tags":["Video"],"subscriptions":0,"fileSize":0}"#
    let old = try JSONDecoder().decode(WorkshopItem.self, from: Data(legacy.utf8))
    try check(old.isVideo, "backward compatible metadata")

    StubProtocol.respond = { request in
      let input = try parameters(request)
      try check(request.url!.path.contains("GetUserFiles"), "author endpoint")
      try check(input["steamid"] as? String == "42" && input["type"] as? String == "myfiles", "author parameters")
      try check(input["sortmethod"] as? String == "score", "author sort")
      try check(input["requiredtags"] == nil, "author must not force Video")
      return (200, #"{"response":{"total":90,"publishedfiledetails":[{"result":9,"publishedfileid":"1"},{"result":1,"publishedfileid":"2","title":"Scene","consumer_appid":431960,"tags":[{"tag":"Scene"}]}]}}"#)
    }
    let page = try await api.fetchDiscovery(route: .author(id: "42", name: "Name"), page: 1, query: "", sort: .highestRated)
    try check(page.items.count == 1 && !page.items[0].isVideo && page.hasMore, "author includes non-video works and continues pagination")

    let suite = "WorkshopFiltersTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try check(WorkshopFilters.load(from: defaults).wallpaperType == nil, "default type is all")
    var remembered = WorkshopFilters()
    remembered.wallpaperType = "Video"
    remembered.ratings = ["Everyone", "Mature"]
    remembered.resolution = "3840 x 2160"
    remembered.genres = ["Anime"]
    remembered.excludedGenres = ["Sports"]
    remembered.save(to: defaults)
    try check(WorkshopFilters.load(from: UserDefaults(suiteName: suite)!) == remembered, "persist every filter")
    WorkshopFilters().save(to: defaults)
    try check(WorkshopFilters.load(from: defaults).isDefault, "reset is persisted")

    try await MainActor.run {
      let favoriteSuite = "FavoriteLibraryTests." + UUID().uuidString
      let favoriteDefaults = UserDefaults(suiteName: favoriteSuite)!
      defer { favoriteDefaults.removePersistentDomain(forName: favoriteSuite) }
      let library = FavoriteLibrary(defaults: favoriteDefaults)
      library.toggleAuthor(id: "42", name: "Creator")
      library.toggleCollection(
        id: "123",
        title: "Collection",
        previewURL: URL(string: "https://example.com/cover.jpg"),
        memberCount: 2
      )
      try check(library.containsAuthor("42"), "favorite author inserted")
      try check(library.containsCollection("123"), "favorite collection inserted")
      let reloaded = FavoriteLibrary(defaults: favoriteDefaults)
      try check(reloaded.authors.first?.name == "Creator", "favorite author persisted")
      try check(reloaded.collections.first?.memberCount == 2, "favorite collection persisted")
      reloaded.removeAuthor("42")
      reloaded.removeCollection("123")
      let emptied = FavoriteLibrary(defaults: favoriteDefaults)
      try check(emptied.totalCount == 0, "favorite removal persisted")
    }

    let manifest = #"""
    "AppWorkshop"
    {
      "WorkshopItemsInstalled"
      {
        "111"
        {
          "manifest" "old"
        }
        "222"
        {
          "manifest" "keep"
        }
      }
      "WorkshopItemDetails"
      {
        "111"
        {
          "BytesDownloaded" "0"
        }
        "222"
        {
          "manifest" "keep"
        }
      }
      "Unrelated"
      {
        "111" "must remain"
      }
    }
    """#
    let repairedManifest = WorkshopManifestStateRepair.removingItem("111", fromManifest: manifest)
    try check(repairedManifest.removed, "stale workshop entry removed")
    let remainingStaleIDCount = repairedManifest.text.components(separatedBy: "\"111\"").count - 1
    try check(remainingStaleIDCount == 1, "both stale workshop blocks removed")
    try check(repairedManifest.text.contains(#""111" "must remain""#), "unrelated manifest data preserved")
    try check(repairedManifest.text.contains(#""222""#), "healthy workshop entries preserved")

    let recoveryRoot = FileManager.default.temporaryDirectory
      .appending(path: "WorkshopRecoveryTests.\(UUID().uuidString)", directoryHint: .isDirectory)
    let recoverySteamapps = recoveryRoot.appending(path: "steamapps", directoryHint: .isDirectory)
    let recoveryWorkshop = recoverySteamapps.appending(path: "workshop", directoryHint: .isDirectory)
    let recoveryLogs = recoveryRoot.appending(path: "logs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: recoveryWorkshop, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recoveryLogs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: recoveryRoot) }
    let recoveryManifest = recoveryWorkshop.appending(path: "appworkshop_431960.acf")
    let recoveryLog = recoveryLogs.appending(path: "workshop_log.txt")
    try Data(manifest.utf8).write(to: recoveryManifest)
    try Data().write(to: recoveryLog)
    let checkpoint = WorkshopManifestStateRepair.checkpoint(in: [recoverySteamapps])
    let missingPath = recoverySteamapps
      .appending(path: "workshop/content/431960/111/preview.jpg").path
    let recoveryOutput = """
      [AppID 431960] Update canceled: (File Not Found) (Missing game files) "\(missingPath)"
      [AppID 431960] Download item 333 result : Failure
      """
    try Data(recoveryOutput.utf8).write(to: recoveryLog)
    let recovery = await WorkshopManifestStateRepair.repairMissingSource(
      in: [recoverySteamapps], after: checkpoint, requestedID: "333"
    )
    try check(recovery?.missingWorkshopID == "111", "missing workshop source identified")
    let recoveredText = try String(contentsOf: recoveryManifest, encoding: .utf8)
    let recoveredIDCount = recoveredText.components(separatedBy: "\"111\"").count - 1
    try check(recoveredIDCount == 1, "missing workshop source repaired from new log output")
    try check(
      FileManager.default.fileExists(
        atPath: recoveryManifest.appendingPathExtension("wallpaper-browser-backup").path
      ),
      "workshop manifest backed up before repair"
    )

    let extractionRoot = FileManager.default.temporaryDirectory
      .appending(path: "VideoFirstExtractionTests.\(UUID().uuidString)", directoryHint: .isDirectory)
    let source = extractionRoot.appending(path: "source", directoryHint: .isDirectory)
    let destination = extractionRoot.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractionRoot) }
    let fallbackVideo = source.appending(path: "wallpaper.mp4")
    try Data(repeating: 7, count: 4_096).write(to: fallbackVideo)
    try Data(#"{"file":"preview.jpg","title":"Not a video","type":"scene"}"#.utf8)
      .write(to: source.appending(path: "project.json"))
    try Data(repeating: 3, count: 64).write(to: source.appending(path: "preview.jpg"))
    let fallbackItem = WorkshopItem(
      id: "333", creatorSteamID: nil, title: "Fallback", summary: "", previewURL: nil,
      tags: ["Video"], subscriptions: 0, fileSize: 4_096
    )
    let extracted = try await VideoExtractor().extract(
      from: source,
      item: fallbackItem,
      to: destination
    )
    try check(FileManager.default.fileExists(atPath: extracted.url.path), "video extracted without project metadata")
    try check(FileManager.default.fileExists(atPath: fallbackVideo.path), "workshop source retained")

    for type in [String?.none, "Video"] {
      StubProtocol.respond = { request in
        let tags = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
          .filter { $0.name.hasPrefix("requiredtags[") }.compactMap(\.value)
        try check(tags.contains("Video") == (type == "Video"), "Video is an optional filter")
        return (200, #"{"response":{"total":1,"publishedfiledetails":[{"result":1,"publishedfileid":"4","title":"Scene wallpaper","consumer_appid":431960,"tags":[{"tag":"Scene"}]}]}}"#)
      }
      var filters = WorkshopFilters()
      filters.wallpaperType = type
      let results = try await api.fetchItems(query: "", sortOrder: .newest, trendPeriod: .week, filters: filters, page: 1)
      if type == nil { try check(results.items.count == 1 && !results.items[0].isVideo, "browse retains Scene results") }
    }

    StubProtocol.respond = { request in
      let input = try parameters(request)
      try check(input["child_publishedfileid"] as? String == "123" && input["filetype"] as? Int == 1, "reverse collection lookup")
      try check(input["query_type"] as? Int == 21 && input["search_text"] as? String == "winter", "search honors selected sort")
      return (200, #"{"response":{"total":0,"publishedfiledetails":[]}}"#)
    }
    _ = try await api.fetchDiscovery(route: .collections(containing: "123"), page: 1, query: "winter", sort: .recentlyUpdated)
    StubProtocol.respond = { _ in (200, #"{"response":{"publishedfiledetails":[{"result":1,"publishedfileid":"123","title":"Wrong app","consumer_appid":570}]}}"#) }
    do { _ = try await api.fetchDetails(id: "123"); throw CheckFailure.failed("wrong app accepted") }
    catch WorkshopAPIError.itemUnavailable {}
    StubProtocol.respond = { _ in (403, "") }
    do { _ = try await api.fetchDetails(id: "123"); throw CheckFailure.failed("403 accepted") }
    catch WorkshopAPIError.invalidAPIKey {}
    let missing = WorkshopAPIClient(apiKeyProvider: { "" }, session: session)
    do { _ = try await missing.fetchDetails(id: "123"); throw CheckFailure.failed("missing key accepted") }
    catch WorkshopAPIError.missingAPIKey {}
    print("PASS: link parsing, metadata compatibility, favorites persistence, video-first extraction, workshop cache repair, details, previews, collection ordering, filtered pagination, error handling")
  }

  private static func parameters(_ request: URLRequest) throws -> [String: Any] {
    let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "input_json" }!.value!
    return try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
  }

  private static func live() async throws {
    let key = readLine() ?? ""
    try check(!key.isEmpty, "live key supplied via stdin")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let api = WorkshopAPIClient(apiKeyProvider: { key }, session: session)
    let page = try await api.fetchItems(query: "winter", sortOrder: .recentlyUpdated, trendPeriod: .week, filters: WorkshopFilters(), page: 1, pageSize: 2)
    try check(!page.items.isEmpty, "live search")
    let details = try await api.fetchDetails(id: page.items[0].id)
    try check(!details.item.isCollection, "live detail")
    if let id = details.item.creatorSteamID {
      let author = try await api.fetchDiscovery(route: .author(id: id, name: ""), page: 1, query: "", sort: .newest)
      try check(!author.items.isEmpty && author.items.allSatisfy { $0.creatorSteamID == id }, "live author")
      _ = try await api.fetchCreator(id: id)
    }
    let collections = try await api.fetchDiscovery(route: .collections(containing: "3314492008"), page: 1, query: "", sort: .newest)
    try check(!collections.items.isEmpty, "live containing collections")
    let collection = try await api.fetchDetails(id: collections.items[0].id)
    try check(collection.item.isCollection && !collection.childIDs.isEmpty, "live collection members")
    let members = try await api.fetchDetails(ids: Array(collection.childIDs.prefix(5)))
    try check(!members.isEmpty, "live batch member details")
    print("PASS: live search, details, author files/profile, containing collections, collection members")
  }
}
