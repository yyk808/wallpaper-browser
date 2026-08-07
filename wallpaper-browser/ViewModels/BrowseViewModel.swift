import Combine
import Foundation

@MainActor
final class BrowseViewModel: ObservableObject {
  @Published private(set) var items: [WorkshopItem] = []
  @Published var searchText = ""
  @Published var sortOrder: WorkshopSortOrder = .trending
  @Published var filters = WorkshopFilters()
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var totalCount = 0

  private let apiClient: WorkshopAPIClient
  private var currentPage = 1
  private var searchTask: Task<Void, Never>?
  private var hasMorePages = true

  init(apiClient: WorkshopAPIClient? = nil) {
    self.apiClient = apiClient ?? WorkshopAPIClient()
  }

  var hasAPIKey: Bool {
    !CredentialStore.shared.loadAPIKey().isEmpty
  }

  var canLoadMore: Bool {
    hasMorePages && !isLoading && !items.isEmpty
  }

  func refresh() {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      await self?.fetch(reset: true)
    }
  }

  func scheduleSearch() {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await self?.fetch(reset: true)
    }
  }

  func applyFilters(_ filters: WorkshopFilters) {
    self.filters = filters
    refresh()
  }

  func clearFilters() {
    applyFilters(WorkshopFilters())
  }

  func removeRating(_ rating: String) {
    filters.ratings.remove(rating)
    refresh()
  }

  func removeResolution() {
    filters.resolution = nil
    refresh()
  }

  func removeGenre(_ genre: String) {
    filters.genres.remove(genre)
    refresh()
  }

  func loadMore() async {
    guard canLoadMore else { return }
    await fetch(reset: false)
  }

  private func fetch(reset: Bool) async {
    if reset {
      currentPage = 1
      hasMorePages = true
    }
    isLoading = true
    errorMessage = nil

    do {
      let page = try await apiClient.fetchItems(
        query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
        sortOrder: sortOrder,
        filters: filters,
        page: currentPage
      )
      guard !Task.isCancelled else { return }
      if reset {
        items = page.items
      } else {
        let existingIDs = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
      }
      totalCount = page.totalCount
      hasMorePages = !page.items.isEmpty && items.count < page.totalCount
      if hasMorePages { currentPage += 1 }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      if reset { items = [] }
    }
    isLoading = false
  }
}
