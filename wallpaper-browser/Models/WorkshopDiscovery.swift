import Foundation

struct WorkshopDetails: Sendable {
  let item: WorkshopItem
  let description: String
  let createdAt: Date?
  let updatedAt: Date?
  let previews: [WorkshopMedia]
  let childIDs: [String]
  let views: Int?
  let favorites: Int?
}

struct WorkshopMedia: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable { case image, videoLink }
  let url: URL
  let kind: Kind
  var id: String { url.absoluteString }
}

struct WorkshopCreator: Sendable {
  let name: String
  let avatarURL: URL?
  let profileURL: URL?
}

enum WorkshopReference: Hashable, Sendable {
  case file(String)
  case creator(String)
  case vanity(String)

  init?(text: String) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.validID(value) { self = .file(value); return }
    guard let url = URLComponents(string: value),
      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      ["steamcommunity.com", "www.steamcommunity.com"].contains(url.host?.lowercased() ?? "")
    else { return nil }
    let path = url.path.split(separator: "/").map(String.init)
    if path == ["sharedfiles", "filedetails"] || path == ["workshop", "filedetails"],
      let id = url.queryItems?.first(where: { $0.name == "id" })?.value, Self.validID(id)
    { self = .file(id); return }
    if path.count >= 2, path[0] == "profiles", Self.validID(path[1]) {
      self = .creator(path[1]); return
    }
    if path.count >= 2, path[0] == "id", !path[1].isEmpty {
      self = .vanity(path[1]); return
    }
    return nil
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
      && UInt64(value).map { $0 > 0 } == true
  }
}

enum WorkshopExploreRoute: Hashable {
  case author(id: String, name: String)
  case tag(String)
  case collections(containing: String?)
  case collection(id: String, title: String)
  case item(WorkshopItem)
  case lookup(WorkshopReference)
}

struct WorkshopDiscoveryPage: Sendable {
  let items: [WorkshopItem]
  let total: Int
  // Based on the unfiltered response so hidden/unsupported entries cannot stop pagination early.
  let hasMore: Bool
}
