import Combine
import Foundation

@MainActor
final class BrowseViewModel: ObservableObject {
  @Published private(set) var items: [WorkshopItem] = []
  @Published var searchText = ""
  @Published var sortOrder: WorkshopSortOrder = .trending
  @Published var trendPeriod: WorkshopTrendPeriod = .week
  @Published var filters = WorkshopFilters()
  @Published private(set) var previewRefreshToken = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var totalCount = 0

  private let apiClient: WorkshopAPIClient
  private var currentPage = 1
  private var searchTask: Task<Void, Never>?
  private var hasMorePages = true
  private var cachedResults: [BrowseQueryKey: CachedBrowseResult] = [:]
  private var activeQueryKey: BrowseQueryKey?
  private(set) var savedScrollItemID: String?

  private static let maxCachedQueries = 8

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
    activeQueryKey = currentQueryKey
    searchTask = Task { [weak self] in
      await self?.fetch(reset: true, useCache: false)
    }
  }

  func refreshPreviews() {
    previewRefreshToken &+= 1
  }

  func saveScrollPosition(_ itemID: String?) {
    savedScrollItemID = itemID
  }

  func scheduleSearch() {
    searchTask?.cancel()
    activeQueryKey = currentQueryKey
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await self?.fetch(reset: true, useCache: true)
    }
  }

  func loadCachedOrFetch() {
    searchTask?.cancel()
    activeQueryKey = currentQueryKey
    searchTask = Task { [weak self] in
      await self?.fetch(reset: true, useCache: true)
    }
  }

  func applyFilters(_ filters: WorkshopFilters) {
    self.filters = filters
    loadCachedOrFetch()
  }

  func clearFilters() {
    applyFilters(WorkshopFilters())
  }

  func removeRating(_ rating: String) {
    filters.ratings.remove(rating)
    loadCachedOrFetch()
  }

  func removeResolution() {
    filters.resolution = nil
    loadCachedOrFetch()
  }

  func removeGenre(_ genre: String) {
    filters.genres.remove(genre)
    loadCachedOrFetch()
  }

  func removeExcludedGenre(_ genre: String) {
    filters.excludedGenres.remove(genre)
    loadCachedOrFetch()
  }

  func loadMore() async {
    guard canLoadMore, activeQueryKey == currentQueryKey else { return }
    await fetch(reset: false, useCache: true)
  }

  private func fetch(reset: Bool, useCache: Bool) async {
    let queryKey = currentQueryKey

    if reset {
      activeQueryKey = queryKey
      currentPage = 1
      hasMorePages = true
    } else if activeQueryKey != queryKey {
      return
    }

    if useCache, reset, let cachedResult = cachedResults[queryKey] {
      cachedResults[queryKey]?.lastAccessed = Date()
      restore(cachedResult)
      return
    }

    let pageNumber = currentPage
    if !useCache, reset {
      cachedResults.removeValue(forKey: queryKey)
    }

    isLoading = true
    errorMessage = nil
    defer {
      if activeQueryKey == queryKey {
        isLoading = false
      }
    }

    do {
      let page = try await apiClient.fetchItems(
        query: queryKey.query,
        sortOrder: queryKey.sortOrder,
        trendPeriod: queryKey.trendPeriod,
        filters: queryKey.filters,
        page: pageNumber
      )
      guard !Task.isCancelled, activeQueryKey == queryKey else { return }
      if reset {
        items = page.items
      } else {
        let existingIDs = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
      }
      totalCount = page.totalCount
      hasMorePages = !page.items.isEmpty && items.count < page.totalCount
      currentPage = hasMorePages ? pageNumber + 1 : pageNumber
      cache(
        page: page,
        for: queryKey,
        pageNumber: pageNumber,
        reset: reset
      )
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, activeQueryKey == queryKey else { return }
      errorMessage = error.localizedDescription
      if reset { items = [] }
    }
  }

  private var currentQueryKey: BrowseQueryKey {
    BrowseQueryKey(
      query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
      sortOrder: sortOrder,
      trendPeriod: trendPeriod,
      filters: filters
    )
  }

  private func restore(_ cachedResult: CachedBrowseResult) {
    items = cachedResult.items
    totalCount = cachedResult.totalCount
    currentPage = cachedResult.nextPage
    hasMorePages = cachedResult.hasMorePages
    errorMessage = nil
    isLoading = false
  }

  private func cache(
    page: WorkshopPage,
    for queryKey: BrowseQueryKey,
    pageNumber: Int,
    reset: Bool
  ) {
    var cachedResult = cachedResults[queryKey] ?? CachedBrowseResult()
    if reset {
      cachedResult.items = page.items
    } else {
      let existingIDs = Set(cachedResult.items.map(\.id))
      cachedResult.items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
    }
    cachedResult.totalCount = page.totalCount
    cachedResult.hasMorePages =
      !page.items.isEmpty && cachedResult.items.count < page.totalCount
    cachedResult.nextPage = cachedResult.hasMorePages ? pageNumber + 1 : pageNumber
    cachedResult.lastAccessed = Date()
    cachedResults[queryKey] = cachedResult

    if cachedResults.count > Self.maxCachedQueries {
      let oldestKey = cachedResults.min { lhs, rhs in
        lhs.value.lastAccessed < rhs.value.lastAccessed
      }?.key
      if let oldestKey, oldestKey != queryKey {
        cachedResults.removeValue(forKey: oldestKey)
      }
    }
  }
}

private struct BrowseQueryKey: Hashable {
  let query: String
  let sortOrder: WorkshopSortOrder
  let trendPeriod: WorkshopTrendPeriod
  let filters: WorkshopFilters
}

private struct CachedBrowseResult {
  var items: [WorkshopItem] = []
  var totalCount = 0
  var nextPage = 1
  var hasMorePages = true
  var lastAccessed = Date()
}
