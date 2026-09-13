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
  private var requestGeneration = 0

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
    // Invalidate the previous request before clearing its state. A response from
    // that request must not repopulate the view while the retry is in flight.
    requestGeneration += 1
    setComments([])
    setTotalCount(0)
    nextOffset = 0
    await load(offset: 0)
  }

  private func load(offset: Int) async {
    requestGeneration += 1
    let generation = requestGeneration

    guard !Task.isCancelled else {
      setIsLoading(false)
      return
    }

    setIsLoading(true)
    setErrorMessage(nil)
    defer {
      if generation == requestGeneration {
        setIsLoading(false)
      }
    }

    do {
      let page = try await apiClient.fetchComments(for: item, offset: offset)
      guard isCurrentRequest(generation) else { return }
      if offset == 0 {
        setComments(page.comments)
      } else {
        var seenIDs = Set<String>(minimumCapacity: comments.count + page.comments.count)
        seenIDs.formUnion(comments.lazy.map(\.id))

        var additions: [WorkshopComment] = []
        additions.reserveCapacity(page.comments.count)
        for comment in page.comments where seenIDs.insert(comment.id).inserted {
          additions.append(comment)
        }
        if !additions.isEmpty {
          setComments(comments + additions)
        }
      }
      setTotalCount(page.totalCount)
      nextOffset = page.nextOffset
    } catch is CancellationError {
      return
    } catch {
      guard isCurrentRequest(generation) else { return }
      setErrorMessage(error.localizedDescription)
    }
  }

  private func isCurrentRequest(_ generation: Int) -> Bool {
    generation == requestGeneration && !Task.isCancelled
  }

  private func setComments(_ newComments: [WorkshopComment]) {
    guard comments != newComments else { return }
    comments = newComments
  }

  private func setTotalCount(_ newTotalCount: Int) {
    guard totalCount != newTotalCount else { return }
    totalCount = newTotalCount
  }

  private func setIsLoading(_ newIsLoading: Bool) {
    guard isLoading != newIsLoading else { return }
    isLoading = newIsLoading
  }

  private func setErrorMessage(_ newErrorMessage: String?) {
    guard errorMessage != newErrorMessage else { return }
    errorMessage = newErrorMessage
  }
}
