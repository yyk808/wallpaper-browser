import Foundation

enum WorkshopAPIError: LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case invalidResponse
  case itemUnavailable
  case wrongApp
  case invalidLink
  case commentsUnavailable
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "api.error.missingKey"
    case .invalidAPIKey: "api.error.invalidKey"
    case .invalidResponse: "api.error.invalidResponse"
    case .itemUnavailable: "api.error.itemUnavailable"
    case .wrongApp: "api.error.wrongApp"
    case .invalidLink: "api.error.invalidLink"
    case .commentsUnavailable: "api.error.commentsUnavailable"
    case .httpStatus(let status): "api.error.httpStatus|\(status)"
    }
  }
}

nonisolated struct WorkshopAPIClient: Sendable {
  static let wallpaperEngineAppID = 431_960

  private let apiKeyProvider: @Sendable () -> String
  private let session: URLSession

  init(
    credentialStore: CredentialStore = .shared,
    session: URLSession = .shared
  ) {
    apiKeyProvider = { credentialStore.loadAPIKey() }
    self.session = session
  }

  init(
    apiKeyProvider: @escaping @Sendable () -> String,
    session: URLSession
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.session = session
  }

  func fetchItems(
    query: String,
    sortOrder: WorkshopSortOrder,
    trendPeriod: WorkshopTrendPeriod,
    filters: WorkshopFilters,
    page: Int,
    pageSize: Int = 30
  ) async throws -> WorkshopPage {
    let apiKey = apiKeyProvider()
    guard !apiKey.isEmpty else { throw WorkshopAPIError.missingAPIKey }

    var components = URLComponents(
      string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/"
    )!
    var queryItems = [
      URLQueryItem(name: "key", value: apiKey),
      URLQueryItem(name: "appid", value: String(Self.wallpaperEngineAppID)),
      URLQueryItem(name: "query_type", value: String(sortOrder.queryType)),
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "numperpage", value: String(pageSize)),
      URLQueryItem(name: "filetype", value: "0"),
      URLQueryItem(name: "match_all_tags", value: "true"),
      URLQueryItem(name: "return_tags", value: "true"),
      URLQueryItem(name: "return_previews", value: "true"),
      URLQueryItem(name: "return_short_description", value: "true"),
      URLQueryItem(name: "return_vote_data", value: "true"),
    ]

    if !query.isEmpty {
      queryItems.append(URLQueryItem(name: "search_text", value: query))
    }
    if sortOrder == .trending {
      queryItems.append(URLQueryItem(name: "days", value: String(trendPeriod.rawValue)))
    }

    var requiredTags: [String] = filters.wallpaperType.map { [$0] } ?? []
    if filters.ratings.count == 1, let rating = filters.ratings.first {
      requiredTags.append(rating)
    }
    if let resolution = filters.resolution {
      requiredTags.append(resolution)
    }
    requiredTags.append(contentsOf: filters.genres.sorted())

    for (index, tag) in requiredTags.enumerated() {
      queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
    }

    var excludedTags = filters.excludedGenres
    if filters.ratings.count > 1 && filters.ratings.count < WorkshopFilters.contentRatings.count {
      excludedTags.formUnion(Set(WorkshopFilters.contentRatings).subtracting(filters.ratings))
    }
    for (index, tag) in excludedTags.sorted().enumerated() {
      queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
    }

    components.queryItems = queryItems
    guard let url = components.url else { throw WorkshopAPIError.invalidResponse }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WorkshopAPIError.invalidResponse
    }
    if httpResponse.statusCode == 403 { throw WorkshopAPIError.invalidAPIKey }
    guard httpResponse.statusCode == 200 else {
      throw WorkshopAPIError.httpStatus(httpResponse.statusCode)
    }

    let payload = try JSONDecoder().decode(QueryEnvelope.self, from: data)
    let details = payload.response.publishedFileDetails
      .filter { $0.isAvailable }

    let creatorNames = await fetchCreatorNames(
      for: details.compactMap(\.creatorSteamID).filter { !$0.isEmpty }
    )
    let items = details.map { detail in
      detail.workshopItem(creatorName: detail.creatorSteamID.flatMap { creatorNames[$0] })
    }
    return WorkshopPage(items: items, totalCount: payload.response.total)
  }

  private func fetchCreatorNames(for steamIDs: [String]) async -> [String: String] {
    let uniqueIDs = Array(Set(steamIDs)).sorted()
    guard !uniqueIDs.isEmpty else { return [:] }

    return await WorkshopCreatorNameCache.shared.names(for: uniqueIDs) { missingIDs in
      await requestCreatorNames(for: missingIDs)
    }
  }

  private func requestCreatorNames(for steamIDs: [String]) async -> [String: String] {
    guard !steamIDs.isEmpty else { return [:] }

    var components = URLComponents(
      string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/"
    )!
    components.queryItems = [
      URLQueryItem(name: "key", value: apiKeyProvider()),
      URLQueryItem(name: "steamids", value: steamIDs.joined(separator: ",")),
    ]
    guard let url = components.url else { return [:] }

    do {
      let (data, response) = try await session.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
      let payload = try JSONDecoder().decode(PlayerSummariesEnvelope.self, from: data)
      return Dictionary(uniqueKeysWithValues: payload.response.players.compactMap { player in
        guard !player.steamID.isEmpty, !player.personaName.isEmpty else { return nil }
        return (player.steamID, player.personaName)
      })
    } catch {
      return [:]
    }
  }

  func fetchComments(
    for item: WorkshopItem,
    offset: Int,
    count: Int = 10
  ) async throws -> WorkshopCommentsPage {
    guard let creatorSteamID = item.creatorSteamID, !creatorSteamID.isEmpty else {
      throw WorkshopAPIError.commentsUnavailable
    }

    var components = URLComponents(
      string:
        "https://steamcommunity.com/comment/PublishedFile_Public/render/\(creatorSteamID)/\(item.id)/"
    )!
    components.queryItems = [
      URLQueryItem(name: "start", value: String(offset)),
      URLQueryItem(name: "count", value: String(count)),
    ]
    guard let url = components.url else { throw WorkshopAPIError.invalidResponse }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WorkshopAPIError.invalidResponse
    }
    guard httpResponse.statusCode == 200 else {
      throw WorkshopAPIError.httpStatus(httpResponse.statusCode)
    }

    let payload = try JSONDecoder().decode(CommentRenderResponse.self, from: data)
    guard payload.success else { throw WorkshopAPIError.commentsUnavailable }
    let comments = try SteamCommentHTMLParser.parse(payload.commentsHTML)
    return WorkshopCommentsPage(
      comments: comments,
      totalCount: payload.totalCount,
      nextOffset: offset + count
    )
  }
}

private actor WorkshopCreatorNameCache {
  static let shared = WorkshopCreatorNameCache()

  private var entries: [String: CreatorNameEntry] = [:]
  private var inFlightLoads: [String: CreatorNameLoad] = [:]
  private static let lifetime: TimeInterval = 6 * 60 * 60
  private static let maximumEntryCount = 4_096

  func names(
    for steamIDs: [String],
    load: @escaping @Sendable ([String]) async -> [String: String]
  ) async -> [String: String] {
    let now = Date()
    var names: [String: String] = [:]
    var loadsByID: [UUID: CreatorNameLoad] = [:]
    var unloadedIDs: [String] = []

    for steamID in steamIDs {
      if let entry = entries[steamID], entry.expiresAt > now {
        names[steamID] = entry.name
      } else {
        entries.removeValue(forKey: steamID)
        if let inFlightLoad = inFlightLoads[steamID] {
          loadsByID[inFlightLoad.id] = inFlightLoad
        } else {
          unloadedIDs.append(steamID)
        }
      }
    }

    if !unloadedIDs.isEmpty {
      let id = UUID()
      let task = Task { await load(unloadedIDs) }
      let creatorNameLoad = CreatorNameLoad(
        id: id,
        steamIDs: Set(unloadedIDs),
        task: task
      )
      for steamID in unloadedIDs {
        inFlightLoads[steamID] = creatorNameLoad
      }
      loadsByID[id] = creatorNameLoad
    }

    for creatorNameLoad in loadsByID.values {
      let loadedNames = await creatorNameLoad.task.value
      let expiresAt = Date().addingTimeInterval(Self.lifetime)
      for (steamID, name) in loadedNames where !name.isEmpty {
        entries[steamID] = CreatorNameEntry(name: name, expiresAt: expiresAt)
        if creatorNameLoad.steamIDs.contains(steamID) {
          names[steamID] = name
        }
      }
      for steamID in creatorNameLoad.steamIDs
      where inFlightLoads[steamID]?.id == creatorNameLoad.id {
        inFlightLoads.removeValue(forKey: steamID)
      }
    }

    trimIfNeeded()
    return names
  }

  private func trimIfNeeded() {
    let overflow = entries.count - Self.maximumEntryCount
    guard overflow > 0 else { return }
    let oldestIDs = entries.sorted { $0.value.expiresAt < $1.value.expiresAt }
      .prefix(overflow)
      .map(\.key)
    for steamID in oldestIDs {
      entries.removeValue(forKey: steamID)
    }
  }
}

private struct CreatorNameEntry {
  let name: String
  let expiresAt: Date
}

private struct CreatorNameLoad {
  let id: UUID
  let steamIDs: Set<String>
  let task: Task<[String: String], Never>
}

private struct QueryEnvelope: Decodable {
  let response: QueryResponse
}

private struct QueryResponse: Decodable {
  let total: Int
  let publishedFileDetails: [WorkshopFileDTO]

  enum CodingKeys: String, CodingKey {
    case total
    case publishedFileDetails = "publishedfiledetails"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    total = container.decodeFlexibleInt(forKey: .total) ?? 0
    publishedFileDetails =
      try container.decodeIfPresent(
        [WorkshopFileDTO].self,
        forKey: .publishedFileDetails
      ) ?? []
  }
}

private struct WorkshopFileDTO: Decodable {
  let id: String
  let creatorSteamID: String?
  let title: String
  let summary: String
  let previewURL: URL?
  let tags: [TagDTO]
  let subscriptions: Int
  let fileSize: Int64
  let ratingScore: Double?
  let positiveVotes: Int
  let negativeVotes: Int
  let numComments: Int
  let voteData: VoteDataDTO?
  let result: Int
  let consumerAppID: Int?
  let fileType: Int
  let fullDescription: String
  let createdAt: Date?
  let updatedAt: Date?
  let previews: [WorkshopPreviewDTO]
  let children: [WorkshopChildDTO]
  let views: Int?
  let favorites: Int?
  let banned: Bool

  var isAvailable: Bool { result == 1 && !banned && !id.isEmpty && !title.isEmpty }

  enum CodingKeys: String, CodingKey {
    case id = "publishedfileid"
    case creatorSteamID = "creator"
    case title
    case summary = "short_description"
    case previewURL = "preview_url"
    case tags
    case subscriptions
    case lifetimeSubscriptions = "lifetime_subscriptions"
    case fileSize = "file_size"
    case ratingScore = "score"
    case voteData = "vote_data"
    case positiveVotes = "votes_up"
    case negativeVotes = "votes_down"
    case numComments = "num_comments"
    case publicComments = "num_comments_public"
    case result, banned, previews, children, views
    case consumerAppID = "consumer_appid"
    case fileType = "file_type"
    case fullDescription = "file_description"
    case description
    case createdAt = "time_created"
    case updatedAt = "time_updated"
    case favorites = "favorited"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    creatorSteamID = try container.decodeIfPresent(String.self, forKey: .creatorSteamID)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    fullDescription = try container.decodeIfPresent(String.self, forKey: .fullDescription)
      ?? container.decodeIfPresent(String.self, forKey: .description) ?? ""
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? fullDescription
    result = container.decodeFlexibleInt(forKey: .result) ?? 1
    consumerAppID = container.decodeFlexibleInt(forKey: .consumerAppID)
    fileType = container.decodeFlexibleInt(forKey: .fileType) ?? 0
    createdAt = container.decodeFlexibleDouble(forKey: .createdAt).map(Date.init(timeIntervalSince1970:))
    updatedAt = container.decodeFlexibleDouble(forKey: .updatedAt).map(Date.init(timeIntervalSince1970:))
    previews = try container.decodeIfPresent([WorkshopPreviewDTO].self, forKey: .previews) ?? []
    children = try container.decodeIfPresent([WorkshopChildDTO].self, forKey: .children) ?? []
    views = container.decodeFlexibleInt(forKey: .views)
    favorites = container.decodeFlexibleInt(forKey: .favorites)
    banned = (try? container.decode(Bool.self, forKey: .banned)) ?? false
    previewURL = try container.decodeIfPresent(String.self, forKey: .previewURL)
      .flatMap(URL.init(string:))
    tags = try container.decodeIfPresent([TagDTO].self, forKey: .tags) ?? []
    subscriptions =
      container.decodeFlexibleInt(forKey: .subscriptions)
      ?? container.decodeFlexibleInt(forKey: .lifetimeSubscriptions)
      ?? 0
    fileSize = container.decodeFlexibleInt64(forKey: .fileSize) ?? 0
    ratingScore = container.decodeFlexibleDouble(forKey: .ratingScore)
    voteData = try? container.decode(VoteDataDTO.self, forKey: .voteData)
    positiveVotes =
      container.decodeFlexibleInt(forKey: .positiveVotes) ?? voteData?.positiveVotes ?? 0
    negativeVotes =
      container.decodeFlexibleInt(forKey: .negativeVotes) ?? voteData?.negativeVotes ?? 0
    numComments = container.decodeFlexibleInt(forKey: .publicComments)
      ?? container.decodeFlexibleInt(forKey: .numComments) ?? 0
  }

  func workshopItem(creatorName: String?) -> WorkshopItem {
    WorkshopItem(
      id: id,
      creatorSteamID: creatorSteamID,
      creatorName: creatorName,
      title: title,
      summary: summary,
      previewURL: previewURL,
      tags: tags.map(\.tag),
      subscriptions: subscriptions,
      fileSize: fileSize,
      ratingScore: ratingScore ?? voteData?.score,
      positiveVotes: positiveVotes,
      negativeVotes: negativeVotes,
      numComments: numComments,
      fileType: fileType
    )
  }
}

private struct VoteDataDTO: Decodable {
  let score: Double?
  let positiveVotes: Int
  let negativeVotes: Int

  enum CodingKeys: String, CodingKey {
    case score
    case positiveVotes = "votes_up"
    case negativeVotes = "votes_down"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    score = container.decodeFlexibleDouble(forKey: .score)
    positiveVotes = container.decodeFlexibleInt(forKey: .positiveVotes) ?? 0
    negativeVotes = container.decodeFlexibleInt(forKey: .negativeVotes) ?? 0
  }
}

private struct PlayerSummariesEnvelope: Decodable {
  let response: PlayerSummariesResponse
}

private struct PlayerSummariesResponse: Decodable {
  let players: [PlayerSummaryDTO]
}

private struct PlayerSummaryDTO: Decodable {
  let steamID: String
  let personaName: String

  enum CodingKeys: String, CodingKey {
    case steamID = "steamid"
    case personaName = "personaname"
  }
}

private struct CommentRenderResponse: Decodable {
  let success: Bool
  let totalCount: Int
  let commentsHTML: String

  enum CodingKeys: String, CodingKey {
    case success
    case totalCount = "total_count"
    case commentsHTML = "comments_html"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try? container.decode(Bool.self, forKey: .success) {
      success = value
    } else {
      success = container.decodeFlexibleInt(forKey: .success) == 1
    }
    totalCount = container.decodeFlexibleInt(forKey: .totalCount) ?? 0
    commentsHTML = try container.decodeIfPresent(String.self, forKey: .commentsHTML) ?? ""
  }
}

private enum SteamCommentHTMLParser {
  static func parse(_ html: String) throws -> [WorkshopComment] {
    let documentHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(html)</body></html>"
    let document = try XMLDocument(xmlString: documentHTML, options: [.documentTidyHTML])
    let nodes = try document.nodes(
      forXPath:
        "//*[contains(concat(' ', normalize-space(@class), ' '), ' commentthread_comment ') and starts-with(@id, 'comment_')]"
    )

    return nodes.compactMap { node in
      guard
        let element = node as? XMLElement,
        let rawID = element.attribute(forName: "id")?.stringValue,
        let text = firstString(
          in: element,
          xpath:
            ".//*[contains(concat(' ', normalize-space(@class), ' '), ' commentthread_comment_text ')]"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { return nil }

      let author = firstString(
        in: element,
        xpath: ".//a[contains(@class, 'commentthread_author_link')]"
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      let timestamp = firstAttribute(
        in: element,
        xpath: ".//div[contains(@class, 'commentthread_comment_timestamp') and @data-timestamp]",
        name: "data-timestamp"
      ).flatMap(TimeInterval.init)
      let avatarString =
        firstAttribute(
          in: element,
          xpath: ".//div[contains(@class, 'commentthread_comment_avatar')]//a//img[1]",
          name: "srcset"
        )
        ?? firstAttribute(
          in: element,
          xpath: ".//div[contains(@class, 'commentthread_comment_avatar')]//a//img[1]",
          name: "src"
        )

      return WorkshopComment(
        id: String(rawID.dropFirst("comment_".count)),
        authorName: author?.isEmpty == false ? author! : "steam.userFallback",
        avatarURL: avatarString.flatMap(URL.init(string:)),
        postedAt: timestamp.map(Date.init(timeIntervalSince1970:)),
        text: text
      )
    }
  }

  private static func firstString(in element: XMLElement, xpath: String) -> String? {
    (try? element.nodes(forXPath: xpath).first?.stringValue) ?? nil
  }

  private static func firstAttribute(
    in element: XMLElement,
    xpath: String,
    name: String
  ) -> String? {
    guard let child = try? element.nodes(forXPath: xpath).first as? XMLElement else { return nil }
    return child.attribute(forName: name)?.stringValue
  }
}

private struct TagDTO: Decodable {
  let tag: String
}

extension KeyedDecodingContainer {
  fileprivate func decodeFlexibleInt(forKey key: Key) -> Int? {
    if let value = try? decode(Int.self, forKey: key) { return value }
    if let value = try? decode(String.self, forKey: key) { return Int(value) }
    return nil
  }

  fileprivate func decodeFlexibleInt64(forKey key: Key) -> Int64? {
    if let value = try? decode(Int64.self, forKey: key) { return value }
    if let value = try? decode(String.self, forKey: key) { return Int64(value) }
    return nil
  }

  fileprivate func decodeFlexibleDouble(forKey key: Key) -> Double? {
    if let value = try? decode(Double.self, forKey: key) { return value }
    if let value = try? decode(String.self, forKey: key) { return Double(value) }
    return nil
  }
}

extension WorkshopAPIClient {
  private func serviceRequest<T: Decodable>(
    _ method: String, parameters: [String: Any], as type: T.Type
  ) async throws -> T {
    let key = apiKeyProvider()
    guard !key.isEmpty else { throw WorkshopAPIError.missingAPIKey }
    var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/\(method)/v1/")!
    let input = try JSONSerialization.data(withJSONObject: parameters)
    components.queryItems = [
      URLQueryItem(name: "key", value: key),
      URLQueryItem(name: "input_json", value: String(decoding: input, as: UTF8.self)),
    ]
    guard let url = components.url else { throw WorkshopAPIError.invalidResponse }
    let (data, response) = try await session.data(from: url)
    try validateResponse(response)
    return try JSONDecoder().decode(type, from: data)
  }

  private func validateResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw WorkshopAPIError.invalidResponse }
    if http.statusCode == 403 { throw WorkshopAPIError.invalidAPIKey }
    guard http.statusCode == 200 else { throw WorkshopAPIError.httpStatus(http.statusCode) }
  }

  func fetchDetails(ids: [String]) async throws -> [WorkshopDetails] {
    guard !ids.isEmpty else { return [] }
    let response = try await serviceRequest("GetDetails", parameters: [
      "publishedfileids": ids,
      "includeadditionalpreviews": true,
      "includechildren": true,
      "includetags": true,
      "includevotes": true,
    ], as: QueryEnvelope.self)
    let files = response.response.publishedFileDetails.filter {
      $0.isAvailable && $0.consumerAppID == Self.wallpaperEngineAppID
    }
    let names = await fetchCreatorNames(for: files.compactMap(\.creatorSteamID))
    return files.map { file in
      var media: [WorkshopMedia] = []
      if let url = file.previewURL, url.isWorkshopWebURL {
        media.append(WorkshopMedia(url: url, kind: .image))
      }
      for preview in file.previews {
        if let medium = preview.medium, !media.contains(where: { $0.url == medium.url }) {
          media.append(medium)
        }
      }
      return WorkshopDetails(
        item: file.workshopItem(creatorName: file.creatorSteamID.flatMap { names[$0] }),
        description: file.fullDescription,
        createdAt: file.createdAt, updatedAt: file.updatedAt, previews: media,
        childIDs: file.children.sorted { ($0.sortorder ?? 0) < ($1.sortorder ?? 0) }.map(\.publishedfileid), views: file.views, favorites: file.favorites
      )
    }
  }

  func fetchDetails(id: String) async throws -> WorkshopDetails {
    guard let detail = try await fetchDetails(ids: [id]).first else {
      throw WorkshopAPIError.itemUnavailable
    }
    return detail
  }

  func fetchDiscovery(
    route: WorkshopExploreRoute, page: Int, query: String, sort: WorkshopSortOrder
  ) async throws -> WorkshopDiscoveryPage {
    var parameters: [String: Any] = [
      "appid": Self.wallpaperEngineAppID, "page": page, "numperpage": 30,
      "return_tags": true, "return_short_description": true, "return_vote_data": true,
      "match_all_tags": true,
    ]
    let method: String
    switch route {
    case .author(let id, _):
      method = "GetUserFiles"
      parameters["steamid"] = id
      parameters["type"] = "myfiles"
      // GetUserFiles uses named sort methods, not QueryFiles query_type values.
      parameters["sortmethod"] = sort == .highestRated ? "score" : "creationorder"
      parameters["filetype"] = 0
    case .tag(let tag):
      method = "QueryFiles"
      parameters["requiredtags"] = [tag]
      parameters["filetype"] = 0
      if !WorkshopFilters.contentRatings.contains(tag) {
        parameters["excludedtags"] = ["Questionable", "Mature"]
      }
      parameters["query_type"] = sort.queryType
      if !query.isEmpty { parameters["search_text"] = query }
      parameters["days"] = 7
    case .collections(let childID):
      method = "QueryFiles"
      parameters["filetype"] = 1
      parameters["query_type"] = sort.queryType
      if !query.isEmpty { parameters["search_text"] = query }
      if let childID { parameters["child_publishedfileid"] = childID }
      parameters["days"] = 7
    default:
      throw WorkshopAPIError.invalidResponse
    }
    let payload = try await serviceRequest(method, parameters: parameters, as: QueryEnvelope.self)
    let raw = payload.response.publishedFileDetails
    let files = raw.filter {
      $0.isAvailable && $0.consumerAppID == Self.wallpaperEngineAppID
        && ($0.fileType == 2 || $0.fileType == 0)
    }
    let names = await fetchCreatorNames(for: files.compactMap(\.creatorSteamID))
    return WorkshopDiscoveryPage(
      items: files.map { $0.workshopItem(creatorName: $0.creatorSteamID.flatMap { names[$0] }) },
      total: payload.response.total,
      hasMore: !raw.isEmpty && page * 30 < payload.response.total
    )
  }

  func fetchCreator(id: String) async throws -> WorkshopCreator? {
    let key = apiKeyProvider()
    guard !key.isEmpty else { throw WorkshopAPIError.missingAPIKey }
    var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
    components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "steamids", value: id)]
    let (data, response) = try await session.data(from: components.url!)
    try validateResponse(response)
    let payload = try JSONDecoder().decode(CreatorEnvelope.self, from: data)
    return payload.response.players.first.map {
      WorkshopCreator(name: $0.personaname, avatarURL: $0.avatarfull.flatMap(URL.init(string:)),
        profileURL: $0.profileurl.flatMap(URL.init(string:)).flatMap { $0.isWorkshopWebURL ? $0 : nil })
    }
  }

  func resolveVanity(_ name: String) async throws -> String {
    let key = apiKeyProvider()
    guard !key.isEmpty else { throw WorkshopAPIError.missingAPIKey }
    var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/ResolveVanityURL/v1/")!
    components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "vanityurl", value: name)]
    let (data, response) = try await session.data(from: components.url!)
    try validateResponse(response)
    let payload = try JSONDecoder().decode(VanityEnvelope.self, from: data)
    guard payload.response.success == 1, let id = payload.response.steamid else {
      throw WorkshopAPIError.itemUnavailable
    }
    return id
  }
}

private struct WorkshopChildDTO: Decodable {
  let publishedfileid: String
  let sortorder: Int?
}

private struct WorkshopPreviewDTO: Decodable {
  let previewType: Int?
  let url: String?
  let videoID: String?
  let externalURL: String?
  enum CodingKeys: String, CodingKey {
    case previewType = "preview_type"
    case url
    case videoID = "youtubevideoid"
    case externalURL = "external_url"
  }
  var medium: WorkshopMedia? {
    if let videoID, !videoID.isEmpty {
      var components = URLComponents(string: "https://www.youtube.com/watch")!
      components.queryItems = [URLQueryItem(name: "v", value: videoID)]
      return components.url.map { WorkshopMedia(url: $0, kind: .videoLink) }
    }
    guard let value = externalURL ?? url, let link = URL(string: value), link.isWorkshopWebURL else { return nil }
    return WorkshopMedia(url: link, kind: previewType == 0 ? .image : .videoLink)
  }
}

private struct CreatorEnvelope: Decodable {
  struct Response: Decodable { let players: [Player] }
  struct Player: Decodable {
    let personaname: String
    let avatarfull: String?
    let profileurl: String?
  }
  let response: Response
}

private struct VanityEnvelope: Decodable {
  struct Response: Decodable { let success: Int; let steamid: String? }
  let response: Response
}

extension URL {
  var isWorkshopWebURL: Bool { ["https", "http"].contains(scheme?.lowercased() ?? "") && host != nil }
}
