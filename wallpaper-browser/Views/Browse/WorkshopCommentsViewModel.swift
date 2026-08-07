import Combine
import Foundation

@MainActor
final class WorkshopCommentsViewModel: ObservableObject {
  @Published private(set) var comments: [WorkshopComment] = []
  @Published private(set) var totalCount = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let item: WorkshopItem
  private let apiClient: WorkshopAPIClient
  private var nextOffset = 0

  init(item: WorkshopItem, apiClient: WorkshopAPIClient = WorkshopAPIClient()) {
    self.item = item
    self.apiClient = apiClient
  }

  var canLoadMore: Bool {
    !isLoading && !comments.isEmpty && nextOffset < totalCount
  }

  func loadInitial() async {
    guard comments.isEmpty, !isLoading else { return }
    await load(offset: 0)
  }

  func loadMore() async {
    guard canLoadMore else { return }
    await load(offset: nextOffset)
  }

  func retry() async {
    comments = []
    totalCount = 0
    nextOffset = 0
    await load(offset: 0)
  }

  private func load(offset: Int) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let page = try await apiClient.fetchComments(for: item, offset: offset)
      guard !Task.isCancelled else { return }
      if offset == 0 {
        comments = page.comments
      } else {
        let existingIDs = Set(comments.map(\.id))
        comments.append(contentsOf: page.comments.filter { !existingIDs.contains($0.id) })
      }
      totalCount = page.totalCount
      nextOffset = page.nextOffset
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }
}
