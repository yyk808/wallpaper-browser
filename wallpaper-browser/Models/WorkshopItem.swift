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
  let numComments: Int
  let fileType: Int

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
    negativeVotes: Int = 0,
    numComments: Int = 0,
    fileType: Int = 0
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
    self.numComments = numComments
    self.fileType = fileType
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
    case numComments
    case fileType
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
    numComments = try container.decodeIfPresent(Int.self, forKey: .numComments) ?? 0
    fileType = try container.decodeIfPresent(Int.self, forKey: .fileType) ?? 0
  }

  var isCollection: Bool { fileType == 2 }
  var isVideo: Bool { !isCollection && tags.contains { $0.caseInsensitiveCompare("Video") == .orderedSame } }

  var ratingText: String? {
    guard let ratingScore else { return nil }
    let normalizedScore = ratingScore <= 1 ? ratingScore * 100 : ratingScore
    return String(format: "%.0f%%", normalizedScore)
  }

  var authorText: String? {
    if let creatorName, !creatorName.isEmpty { return creatorName }
    return creatorSteamID
  }

  var workshopPageURL: URL? {
    guard !id.isEmpty,
      var components = URLComponents(
        string: "https://steamcommunity.com/sharedfiles/filedetails/"
      )
    else {
      return nil
    }

    components.queryItems = [URLQueryItem(name: "id", value: id)]
    return components.url
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
  case recentlyUpdated
  case mostLiked
  case unrated

  var id: Int { rawValue }

  var resetsBrowsePosition: Bool {
    switch self {
    case .trending, .newest, .recentlyUpdated, .unrated: true
    case .highestRated, .mostSubscribed, .mostLiked: false
    }
  }

  var localizationKey: String {
    switch self {
    case .trending: "workshop.sort.trending"
    case .newest: "workshop.sort.newest"
    case .highestRated: "workshop.sort.highestRated"
    case .mostSubscribed: "workshop.sort.mostSubscribed"
    case .recentlyUpdated: "workshop.sort.recentlyUpdated"
    case .mostLiked: "workshop.sort.mostLiked"
    case .unrated: "workshop.sort.unrated"
    }
  }

  var queryType: Int {
    switch self {
    case .trending: 3
    case .newest: 1
    case .highestRated: 0
    case .mostSubscribed: 9
    case .recentlyUpdated: 21
    case .mostLiked: 11
    case .unrated: 8
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

struct WorkshopFilters: Codable, Equatable, Hashable, Sendable {
  var wallpaperType: String?
  static let wallpaperTypes = ["Scene", "Video", "Web", "Application"]
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

  private static let preferencesKey = "workshop.browseFilters.v1"

  static func load(from defaults: UserDefaults) -> WorkshopFilters {
    guard let data = defaults.data(forKey: preferencesKey),
      var filters = try? JSONDecoder().decode(WorkshopFilters.self, from: data)
    else { return WorkshopFilters() }
    if let type = filters.wallpaperType, !wallpaperTypes.contains(type) { filters.wallpaperType = nil }
    return filters
  }

  func save(to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferencesKey) }
  }

  var activeCount: Int {
    let defaultRating = ratings == ["Everyone"]
    return (wallpaperType == nil ? 0 : 1) + (defaultRating ? 0 : ratings.count) + (resolution == nil ? 0 : 1) + genres.count
      + excludedGenres.count
  }

  var isDefault: Bool {
    wallpaperType == nil && ratings == ["Everyone"] && resolution == nil && genres.isEmpty && excludedGenres.isEmpty
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
