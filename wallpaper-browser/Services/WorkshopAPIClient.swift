import Foundation

enum WorkshopAPIError: LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case invalidResponse
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "需要先在设置中填写 Steam Web API Key。"
    case .invalidAPIKey: "Steam Web API Key 无效，请检查后重试。"
    case .invalidResponse: "Steam 返回了无法识别的数据。"
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
  let title: String
  let summary: String
  let previewURL: URL?
  let tags: [TagDTO]
  let subscriptions: Int
  let fileSize: Int64

  enum CodingKeys: String, CodingKey {
    case id = "publishedfileid"
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
      title: title,
      summary: summary,
      previewURL: previewURL,
      tags: tags.map(\.tag),
      subscriptions: subscriptions,
      fileSize: fileSize
    )
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
