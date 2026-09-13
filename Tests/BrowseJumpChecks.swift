import Foundation
import Combine
final class CredentialStore: @unchecked Sendable {
 static let shared = CredentialStore()
 func loadAPIKey() -> String { "test-key" }
}
final class JumpProtocol: URLProtocol, @unchecked Sendable {
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
  let p = Int(q.first { $0.name == "page" }!.value!)!
  let rows = ((p-1)*30+1...min(p*30, 365)).map { ["publishedfileid": String($0), "title": "Item \($0)", "file_type": 0] as [String:Any] }
  let data = try! JSONSerialization.data(withJSONObject: ["response": ["total":365,"publishedfiledetails":rows]])
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:data)
  client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Checks {
 @MainActor static func settled(_ vm: BrowseViewModel) async throws {
  for _ in 0..<200 { if !vm.isLoading { return }; try await Task.sleep(for:.milliseconds(10)) }
  fatalError("Timeout")
 }
 @MainActor static func main() async throws {
  let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JumpProtocol.self]
  let vm = BrowseViewModel(apiClient: WorkshopAPIClient(apiKeyProvider:{"test-key"},session:URLSession(configuration:config)),sortOrder:.highestRated,filterDefaults:nil)
  vm.refresh(); try await settled(vm)
  precondition(vm.items.count == 30 && vm.totalCount == 365)
  vm.jump(to:305); try await settled(vm)
  precondition(vm.firstItemNumber == 301 && vm.jumpTargetID == "305")
  precondition(vm.currentItemNumber == 305)
  await vm.loadMore()
  precondition(vm.currentItemNumber == 305, "Loading more must not advance the counter")
  vm.rememberVisibleItem("342", session: vm.scrollSessionID)
  precondition(vm.currentItemNumber == 342)
  precondition(vm.items.count == 60 && vm.canLoadMore)
  await vm.loadMore()
  precondition(vm.items.count == 65 && !vm.canLoadMore)
  vm.loadCachedOrFetch(); try await settled(vm)
  precondition(vm.firstItemNumber == 301 && vm.items.count == 65)
  vm.jump(to:0); precondition(vm.firstItemNumber == 301)
  vm.jump(to:366); precondition(vm.firstItemNumber == 301)
  vm.jump(to:1); try await settled(vm)
  precondition(vm.firstItemNumber == 1 && vm.jumpTargetID == "1")
  vm.rememberVisibleItem("19", session: vm.scrollSessionID)
  precondition(vm.currentItemNumber == 19)
  var gridNotifications = 0
  let gridSubscription = vm.objectWillChange.sink { gridNotifications += 1 }
  var positionNotifications = 0
  let subscription = vm.position.$itemID.dropFirst().sink { _ in positionNotifications += 1 }
  for _ in 0..<120 { vm.rememberVisibleItem("19", session: vm.scrollSessionID) }
  precondition(positionNotifications == 0, "Scrolling within the same row must not republish position")
  vm.rememberVisibleItem("20", session: vm.scrollSessionID)
  precondition(positionNotifications == 1)
  precondition(gridNotifications == 0, "Position updates must not invalidate the grid")
  gridSubscription.cancel()
  subscription.cancel()
  vm.rememberVisibleItem("19", session: vm.scrollSessionID)
  let originalFilters = vm.filters
  var differentFilters = originalFilters
  differentFilters.wallpaperType = "Video"
  let oldSession = vm.scrollSessionID
  vm.applyFilters(differentFilters); try await settled(vm)
  precondition(vm.initialScrollTargetID == "1")
  vm.rememberVisibleItem("19", session: oldSession)
  precondition(vm.visibleItemID == "1", "Old grid must not overwrite new query")
  vm.rememberVisibleItem("8", session: vm.scrollSessionID)
  vm.applyFilters(originalFilters); try await settled(vm)
  precondition(vm.initialScrollTargetID == "19" && vm.currentItemNumber == 19)
  vm.applyFilters(differentFilters); try await settled(vm)
  precondition(vm.initialScrollTargetID == "8" && vm.currentItemNumber == 8)
  for order in [WorkshopSortOrder.trending, .newest, .recentlyUpdated, .unrated] {
   vm.sortOrder = order
   vm.loadCachedOrFetch(); try await settled(vm)
   vm.jump(to:305); try await settled(vm)
   vm.rememberVisibleItem("310", session: vm.scrollSessionID)
   vm.loadCachedOrFetch(); try await settled(vm)
   precondition(vm.firstItemNumber == 1 && vm.initialScrollTargetID == "1")
  }
  print("PASS: per-filter scroll positions, stale callback protection, time-sensitive resets; jump offset, exact target, following pages, final page, cache restore, bounds, return to first")
 }
}
