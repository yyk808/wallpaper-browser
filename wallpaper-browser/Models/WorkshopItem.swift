import Foundation

struct WorkshopItem: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let creatorSteamID: String?
  let creatorName: String?
  let title: String
  let summary: String
  let previewURL: URL?
  let tags: [String]
  let subscriptions: Int
  let fileSize: Int64
  let ratingScore: Double?
  let positiveVotes: Int
  let negativeVotes: Int

  init(
    id: String,
    creatorSteamID: String?,
    creatorName: String? = nil,
    title: String,
    summary: String,
    previewURL: URL?,
    tags: [String],
    subscriptions: Int,
    fileSize: Int64,
    ratingScore: Double? = nil,
    positiveVotes: Int = 0,
    negativeVotes: Int = 0
  ) {
    self.id = id
    self.creatorSteamID = creatorSteamID
    self.creatorName = creatorName
    self.title = title
    self.summary = summary
    self.previewURL = previewURL
    self.tags = tags
    self.subscriptions = subscriptions
    self.fileSize = fileSize
    self.ratingScore = ratingScore
    self.positiveVotes = positiveVotes
    self.negativeVotes = negativeVotes
  }

  enum CodingKeys: String, CodingKey {
    case id
    case creatorSteamID
    case creatorName
    case title
    case summary
    case previewURL
    case tags
    case subscriptions
    case fileSize
    case ratingScore
    case positiveVotes
    case negativeVotes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    creatorSteamID = try container.decodeIfPresent(String.self, forKey: .creatorSteamID)
    creatorName = try container.decodeIfPresent(String.self, forKey: .creatorName)
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decode(String.self, forKey: .summary)
    previewURL = try container.decodeIfPresent(URL.self, forKey: .previewURL)
    tags = try container.decode([String].self, forKey: .tags)
    subscriptions = try container.decode(Int.self, forKey: .subscriptions)
    fileSize = try container.decode(Int64.self, forKey: .fileSize)
    ratingScore = try container.decodeIfPresent(Double.self, forKey: .ratingScore)
    positiveVotes = try container.decodeIfPresent(Int.self, forKey: .positiveVotes) ?? 0
    negativeVotes = try container.decodeIfPresent(Int.self, forKey: .negativeVotes) ?? 0
  }

  var ratingText: String? {
    guard let ratingScore else { return nil }
    let normalizedScore = ratingScore <= 1 ? ratingScore * 100 : ratingScore
    return String(format: "%.0f%%", normalizedScore)
  }

  var authorText: String? {
    if let creatorName, !creatorName.isEmpty { return creatorName }
    return creatorSteamID
  }

  var genreTags: [String] {
    tags.filter {
      !WorkshopFilters.contentRatings.contains($0) && !WorkshopFilters.resolutions.contains($0)
        && $0.caseInsensitiveCompare("Video") != .orderedSame
    }
  }
}

enum WorkshopSortOrder: Int, CaseIterable, Identifiable, Sendable {
  case trending
  case newest
  case highestRated
  case mostSubscribed

  var id: Int { rawValue }

  var localizationKey: String {
    switch self {
    case .trending: "workshop.sort.trending"
    case .newest: "workshop.sort.newest"
    case .highestRated: "workshop.sort.highestRated"
    case .mostSubscribed: "workshop.sort.mostSubscribed"
    }
  }

  var queryType: Int {
    switch self {
    case .trending: 3
    case .newest: 1
    case .highestRated: 0
    case .mostSubscribed: 9
    }
  }
}

enum WorkshopTrendPeriod: Int, CaseIterable, Identifiable, Sendable {
  case day = 1
  case week = 7
  case month = 30
  case quarter = 90
  case year = 365

  var id: Int { rawValue }

  var localizationKey: String {
    switch self {
    case .day: "workshop.period.day"
    case .week: "workshop.period.week"
    case .month: "workshop.period.month"
    case .quarter: "workshop.period.quarter"
    case .year: "workshop.period.year"
    }
  }
}

struct WorkshopFilters: Equatable, Hashable, Sendable {
  var ratings: Set<String> = ["Everyone"]
  var resolution: String?
  var genres: Set<String> = []
  var excludedGenres: Set<String> = []

  static let contentRatings = ["Everyone", "Questionable", "Mature"]
  static let resolutions = [
    "1920 x 1080",
    "2560 x 1440",
    "3840 x 2160",
    "3440 x 1440",
    "1440 x 2560",
  ]
  static let genres = [
    "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk",
    "Fantasy", "Game", "Girls", "Guys", "Landscape", "Medieval",
    "Memes", "MMD", "Music", "Nature", "Pixel Art", "Relaxing",
    "Retro", "Sci-Fi", "Sports", "Technology", "Television", "Vehicle",
  ]

  var activeCount: Int {
    let defaultRating = ratings == ["Everyone"]
    return (defaultRating ? 0 : ratings.count) + (resolution == nil ? 0 : 1) + genres.count
      + excludedGenres.count
  }

  var isDefault: Bool {
    ratings == ["Everyone"] && resolution == nil && genres.isEmpty && excludedGenres.isEmpty
  }
}

struct WorkshopPage: Sendable {
  let items: [WorkshopItem]
  let totalCount: Int
}

struct WorkshopComment: Identifiable, Hashable, Sendable {
  let id: String
  let authorName: String
  let avatarURL: URL?
  let postedAt: Date?
  let text: String
}

struct WorkshopCommentsPage: Sendable {
  let comments: [WorkshopComment]
  let totalCount: Int
  let nextOffset: Int
}
