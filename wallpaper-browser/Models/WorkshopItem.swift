import Foundation

struct WorkshopItem: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let creatorSteamID: String?
  let title: String
  let summary: String
  let previewURL: URL?
  let tags: [String]
  let subscriptions: Int
  let fileSize: Int64

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

  var title: String {
    switch self {
    case .trending: "热门趋势"
    case .newest: "最新发布"
    case .highestRated: "最高评分"
    case .mostSubscribed: "最多订阅"
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

struct WorkshopFilters: Equatable, Hashable, Sendable {
  var ratings: Set<String> = ["Everyone"]
  var resolution: String?
  var genres: Set<String> = []

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
  }

  var isDefault: Bool {
    ratings == ["Everyone"] && resolution == nil && genres.isEmpty
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
