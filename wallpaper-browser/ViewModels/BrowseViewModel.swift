import Combine
import Foundation

@MainActor
final class BrowseViewModel: ObservableObject {
  @Published private(set) var items: [WorkshopItem] = []
  @Published var searchText = ""
  @Published var sortOrder: WorkshopSortOrder = .trending
  @Published var trendPeriod: WorkshopTrendPeriod = .week
  @Published var filters = WorkshopFilters() {
    didSet { if let filterDefaults { filters.save(to: filterDefaults) } }
  }
  @Published private(set) var previewRefreshToken = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var totalCount = 0
  @Published private(set) var firstItemNumber = 1
  @Published private(set) var jumpTargetID: String?
  @Published private(set) var scrollSessionID = UUID()
  let position = BrowsePositionState()
  var visibleItemID: String? { position.itemID }
  private(set) var initialScrollTargetID: String?
  static let pageSize = 30
  @Published private(set) var hasAPIKey: Bool

  private let apiClient: WorkshopAPIClient
  private let filterDefaults: UserDefaults?
  private var currentPage = 1
  private var searchTask: Task<Void, Never>?
  private var hasMorePages = true
  private var cachedResults: [BrowseQueryKey: CachedBrowseResult] = [:]
  private var activeQueryKey: BrowseQueryKey?
  private var displayedQueryKey: BrowseQueryKey?
  private var requestGeneration = 0

  private static let maxCachedQueries = 8

  init(
    apiClient: WorkshopAPIClient? = nil,
    sortOrder: WorkshopSortOrder = .trending,
    trendPeriod: WorkshopTrendPeriod = .week,
    filterDefaults: UserDefaults? = .standard
  ) {
    self.apiClient = apiClient ?? WorkshopAPIClient()
    self.filterDefaults = filterDefaults
    self.sortOrder = sortOrder
    self.trendPeriod = trendPeriod
    hasAPIKey = !CredentialStore.shared.loadAPIKey().isEmpty
    if let filterDefaults { filters = WorkshopFilters.load(from: filterDefaults) }
  }

  var canLoadMore: Bool {
    hasMorePages && !isLoading && !items.isEmpty
  }

  var currentItemNumber: Int {
    guard !items.isEmpty else { return 0 }
    guard let visibleItemID, let index = items.firstIndex(where: { $0.id == visibleItemID })
    else { return firstItemNumber }
    return firstItemNumber + index
  }

  func rememberVisibleItem(_ id: String?, session: UUID) {
    // Ignore callbacks from the outgoing grid or a query still being replaced.
    guard session == scrollSessionID, activeQueryKey == currentQueryKey,
      displayedQueryKey == currentQueryKey,
      let id, id != visibleItemID, let index = items.firstIndex(where: { $0.id == id }) else { return }
    position.update(id: id, number: firstItemNumber + index)
    if let key = activeQueryKey { cachedResults[key]?.visibleItemID = id }
  }

  func preserveScrollTarget(session: UUID) {
    guard session == scrollSessionID else { return }
    initialScrollTargetID = visibleItemID
  }

  private func resetScroll(to id: String?) {
    position.update(id: id, number: id.flatMap { target in items.firstIndex(where: { $0.id == target }) }.map { firstItemNumber + $0 } ?? firstItemNumber)
    initialScrollTargetID = id
    scrollSessionID = UUID()
  }

  func refresh() {
    refreshCredentialState()
    searchTask?.cancel()
    requestGeneration &+= 1
    let generation = requestGeneration
    activeQueryKey = currentQueryKey
    setLoading(true)
    searchTask = Task { [weak self] in
      await self?.fetch(reset: true, useCache: false, generation: generation)
    }
  }

  func refreshPreviews() {
    previewRefreshToken &+= 1
  }

  func scheduleSearch() {
    searchTask?.cancel()
    requestGeneration &+= 1
    let generation = requestGeneration
    activeQueryKey = currentQueryKey
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await self?.fetch(reset: true, useCache: true, generation: generation)
    }
  }

  func loadCachedOrFetch() {
    refreshCredentialState()
    searchTask?.cancel()
    requestGeneration &+= 1
    let generation = requestGeneration
    activeQueryKey = currentQueryKey
    setLoading(true)
    searchTask = Task { [weak self] in
      await self?.fetch(reset: true, useCache: true, generation: generation)
    }
  }

  func applyFilters(_ filters: WorkshopFilters) {
    self.filters = filters
    loadCachedOrFetch()
  }

  func clearFilters() {
    applyFilters(WorkshopFilters())
  }

  func applyPreset(
    sortOrder: WorkshopSortOrder,
    trendPeriod: WorkshopTrendPeriod = .week
  ) {
    searchTask?.cancel()
    searchText = ""
    self.sortOrder = sortOrder
    self.trendPeriod = trendPeriod
    setItems([])
    setTotalCount(0)
    setErrorMessage(nil)
    loadCachedOrFetch()
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
    await fetch(reset: false, useCache: true, generation: requestGeneration)
  }

  func jump(to number: Int) {
    guard number > 0, number <= totalCount else { return }
    searchTask?.cancel()
    requestGeneration &+= 1
    let generation = requestGeneration
    activeQueryKey = currentQueryKey
    jumpTargetID = nil
    setLoading(true)
    let page = (number - 1) / Self.pageSize + 1
    searchTask = Task { [weak self] in
      guard let self else { return }
      await fetch(reset: true, useCache: false, generation: generation, startingPage: page, startingItem: number)
      guard !Task.isCancelled, generation == requestGeneration, errorMessage == nil else { return }
      let index = number - firstItemNumber
      if items.indices.contains(index) { jumpTargetID = items[index].id }
    }
  }

  private func fetch(reset: Bool, useCache: Bool, generation: Int, startingPage: Int = 1, startingItem: Int? = nil) async {
    guard generation == requestGeneration else { return }
    let queryKey = currentQueryKey
    if WorkshopReference(text: queryKey.query) != nil { setLoading(false); return }

    if reset {
      activeQueryKey = queryKey
      currentPage = startingPage
      jumpTargetID = nil
      hasMorePages = true
    } else if activeQueryKey != queryKey {
      return
    }

    if useCache, reset, !queryKey.sortOrder.resetsBrowsePosition, let cachedResult = cachedResults[queryKey] {
      cachedResults[queryKey]?.lastAccessed = Date()
      displayedQueryKey = queryKey
      restore(cachedResult)
      return
    }

    let pageNumber = currentPage
    if !useCache, reset {
      cachedResults.removeValue(forKey: queryKey)
    }

    setLoading(true)
    setErrorMessage(nil)
    defer {
      if generation == requestGeneration, activeQueryKey == queryKey {
        setLoading(false)
      }
    }

    do {
      let page = try await apiClient.fetchItems(
        query: queryKey.query,
        sortOrder: queryKey.sortOrder,
        trendPeriod: queryKey.trendPeriod,
        filters: queryKey.filters,
        page: pageNumber,
        pageSize: Self.pageSize
      )
      guard !Task.isCancelled, generation == requestGeneration,
        activeQueryKey == queryKey
      else { return }
      if reset {
        displayedQueryKey = queryKey
        firstItemNumber = (pageNumber - 1) * Self.pageSize + 1
        setItems(page.items)
        let index = (startingItem ?? firstItemNumber) - firstItemNumber
        resetScroll(to: page.items.indices.contains(index) ? page.items[index].id : page.items.first?.id)
      } else {
        let existingIDs = Set(items.map(\.id))
        let newItems = page.items.filter { !existingIDs.contains($0.id) }
        if !newItems.isEmpty {
          items.append(contentsOf: newItems)
        }
      }
      setTotalCount(page.totalCount)
      hasMorePages = !page.items.isEmpty && pageNumber * Self.pageSize < page.totalCount
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
      guard !Task.isCancelled, generation == requestGeneration,
        activeQueryKey == queryKey
      else { return }
      setErrorMessage(error.localizedDescription)
      if reset { setItems([]) }
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

  private func refreshCredentialState() {
    let updatedValue = !CredentialStore.shared.loadAPIKey().isEmpty
    if hasAPIKey != updatedValue {
      hasAPIKey = updatedValue
    }
  }

  private func setItems(_ updatedItems: [WorkshopItem]) {
    if items != updatedItems {
      items = updatedItems
    }
  }

  private func setTotalCount(_ updatedTotalCount: Int) {
    if totalCount != updatedTotalCount {
      totalCount = updatedTotalCount
    }
  }

  private func setLoading(_ updatedValue: Bool) {
    if isLoading != updatedValue {
      isLoading = updatedValue
    }
  }

  private func setErrorMessage(_ updatedMessage: String?) {
    if errorMessage != updatedMessage {
      errorMessage = updatedMessage
    }
  }

  private func restore(_ cachedResult: CachedBrowseResult) {
    setItems(cachedResult.items)
    setTotalCount(cachedResult.totalCount)
    firstItemNumber = cachedResult.firstItemNumber
    currentPage = cachedResult.nextPage
    hasMorePages = cachedResult.hasMorePages
    setErrorMessage(nil)
    resetScroll(to: cachedResult.visibleItemID ?? cachedResult.items.first?.id)
    setLoading(false)
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
      cachedResult.firstItemNumber = firstItemNumber
      cachedResult.visibleItemID = visibleItemID
    } else {
      let existingIDs = Set(cachedResult.items.map(\.id))
      cachedResult.items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
    }
    cachedResult.totalCount = page.totalCount
    cachedResult.hasMorePages =
      !page.items.isEmpty && pageNumber * Self.pageSize < page.totalCount
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
  var visibleItemID: String?
  var firstItemNumber = 1
  var items: [WorkshopItem] = []
  var totalCount = 0
  var nextPage = 1
  var hasMorePages = true
  var lastAccessed = Date()
}

@MainActor
final class BrowsePositionState: ObservableObject {
  @Published private(set) var itemID: String?
  @Published private(set) var number = 0

  func update(id: String?, number: Int) {
    if self.number != number { self.number = number }
    if itemID != id { itemID = id }
  }
}
