import Combine

@MainActor
final class WorkshopHomeViewModel: ObservableObject {
  let trending = BrowseViewModel(sortOrder: .trending, trendPeriod: .week, filterDefaults: nil)
  let newest = BrowseViewModel(sortOrder: .newest, filterDefaults: nil)
  let highestRated = BrowseViewModel(sortOrder: .highestRated, filterDefaults: nil)

  var allModels: [BrowseViewModel] {
    [trending, newest, highestRated]
  }

  func loadCachedOrFetch() {
    for model in allModels where model.items.isEmpty && !model.isLoading {
      model.loadCachedOrFetch()
    }
  }

  func refresh() {
    for model in allModels {
      model.refresh()
    }
  }

  func refreshPreviews() {
    for model in allModels {
      model.refreshPreviews()
    }
  }
}
