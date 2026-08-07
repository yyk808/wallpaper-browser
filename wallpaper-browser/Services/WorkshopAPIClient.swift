import Foundation

enum WorkshopAPIError: LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case invalidResponse
  case commentsUnavailable
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "需要先在设置中填写 Steam Web API Key。"
    case .invalidAPIKey: "Steam Web API Key 无效，请检查后重试。"
    case .invalidResponse: "Steam 返回了无法识别的数据。"
    case .commentsUnavailable: "这件作品暂时无法读取评论。"
    case .httpStatus(let status): "Steam 服务请求失败（HTTP \(status)）。"
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
      URLQueryItem(name: "query_type", value: query.isEmpty ? String(sortOrder.queryType) : "12"),
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "numperpage", value: String(pageSize)),
      URLQueryItem(name: "return_tags", value: "true"),
      URLQueryItem(name: "return_previews", value: "true"),
      URLQueryItem(name: "return_short_description", value: "true"),
    ]

    if !query.isEmpty {
      queryItems.append(URLQueryItem(name: "search_text", value: query))
    }

    var requiredTags = ["Video"]
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

    if filters.ratings.count > 1 && filters.ratings.count < WorkshopFilters.contentRatings.count {
      let excluded = Set(WorkshopFilters.contentRatings).subtracting(filters.ratings)
      for (index, tag) in excluded.sorted().enumerated() {
        queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
      }
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
    let items = payload.response.publishedFileDetails
      .map(\.workshopItem)
      .filter { item in
        item.tags.contains { $0.caseInsensitiveCompare("Video") == .orderedSame }
      }
    return WorkshopPage(items: items, totalCount: payload.response.total)
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
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    creatorSteamID = try container.decodeIfPresent(String.self, forKey: .creatorSteamID)
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
    previewURL = try container.decodeIfPresent(String.self, forKey: .previewURL)
      .flatMap(URL.init(string:))
    tags = try container.decodeIfPresent([TagDTO].self, forKey: .tags) ?? []
    subscriptions =
      container.decodeFlexibleInt(forKey: .subscriptions)
      ?? container.decodeFlexibleInt(forKey: .lifetimeSubscriptions)
      ?? 0
    fileSize = container.decodeFlexibleInt64(forKey: .fileSize) ?? 0
  }

  var workshopItem: WorkshopItem {
    WorkshopItem(
      id: id,
      creatorSteamID: creatorSteamID,
      title: title,
      summary: summary,
      previewURL: previewURL,
      tags: tags.map(\.tag),
      subscriptions: subscriptions,
      fileSize: fileSize
    )
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
        authorName: author?.isEmpty == false ? author! : "Steam 用户",
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
}
