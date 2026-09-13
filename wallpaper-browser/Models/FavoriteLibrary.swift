import Combine
import Foundation

struct FavoriteWorkshopAuthor: Codable, Hashable, Identifiable, Sendable {
  let id: String
  var name: String
  var avatarURL: URL?
  var profileURL: URL?
  let savedAt: Date
}

struct FavoriteWorkshopCollection: Codable, Hashable, Identifiable, Sendable {
  let id: String
  var title: String
  var previewURL: URL?
  var creatorName: String?
  var memberCount: Int?
  let savedAt: Date
}

@MainActor
final class FavoriteLibrary: ObservableObject {
  @Published private(set) var authors: [FavoriteWorkshopAuthor]
  @Published private(set) var collections: [FavoriteWorkshopCollection]

  private struct StoredLibrary: Codable {
    var authors: [FavoriteWorkshopAuthor]
    var collections: [FavoriteWorkshopCollection]
  }

  private static let storageKey = "workshop.favoriteLibrary.v1"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.storageKey),
      let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data)
    {
      authors = Self.unique(stored.authors).sorted { $0.savedAt > $1.savedAt }
      collections = Self.unique(stored.collections).sorted { $0.savedAt > $1.savedAt }
    } else {
      authors = []
      collections = []
    }
  }

  var totalCount: Int { authors.count + collections.count }

  func containsAuthor(_ id: String) -> Bool {
    authors.contains { $0.id == id }
  }

  func containsCollection(_ id: String) -> Bool {
    collections.contains { $0.id == id }
  }

  func toggleAuthor(id: String, name: String, creator: WorkshopCreator? = nil) {
    guard !id.isEmpty else { return }
    if containsAuthor(id) {
      removeAuthor(id)
    } else {
      authors.insert(
        FavoriteWorkshopAuthor(
          id: id,
          name: creator?.name.nonEmpty ?? name.nonEmpty ?? id,
          avatarURL: creator?.avatarURL,
          profileURL: creator?.profileURL,
          savedAt: Date()
        ),
        at: 0
      )
      persist()
    }
  }

  func toggleCollection(
    id: String,
    title: String,
    previewURL: URL? = nil,
    creatorName: String? = nil,
    memberCount: Int? = nil
  ) {
    guard !id.isEmpty else { return }
    if containsCollection(id) {
      removeCollection(id)
    } else {
      collections.insert(
        FavoriteWorkshopCollection(
          id: id,
          title: title.nonEmpty ?? id,
          previewURL: previewURL,
          creatorName: creatorName?.nonEmpty,
          memberCount: memberCount,
          savedAt: Date()
        ),
        at: 0
      )
      persist()
    }
  }

  func removeAuthor(_ id: String) {
    guard let index = authors.firstIndex(where: { $0.id == id }) else { return }
    authors.remove(at: index)
    persist()
  }

  func removeCollection(_ id: String) {
    guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
    collections.remove(at: index)
    persist()
  }

  func refreshAuthor(id: String, fallbackName: String, creator: WorkshopCreator?) {
    guard let index = authors.firstIndex(where: { $0.id == id }) else { return }
    var author = authors[index]
    author.name = creator?.name.nonEmpty ?? fallbackName.nonEmpty ?? author.name
    author.avatarURL = creator?.avatarURL ?? author.avatarURL
    author.profileURL = creator?.profileURL ?? author.profileURL
    guard author != authors[index] else { return }
    authors[index] = author
    persist()
  }

  func refreshCollection(_ details: WorkshopDetails) {
    guard let index = collections.firstIndex(where: { $0.id == details.item.id }) else { return }
    var collection = collections[index]
    collection.title = details.item.title.nonEmpty ?? collection.title
    collection.previewURL = details.item.previewURL ?? collection.previewURL
    collection.creatorName = details.item.creatorName?.nonEmpty ?? collection.creatorName
    collection.memberCount = details.childIDs.count
    guard collection != collections[index] else { return }
    collections[index] = collection
    persist()
  }

  private func persist() {
    let stored = StoredLibrary(authors: authors, collections: collections)
    if let data = try? JSONEncoder().encode(stored) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  private static func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
    var seen = Set<T.ID>()
    return values.filter { seen.insert($0.id).inserted }
  }
}

private extension String {
  var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
