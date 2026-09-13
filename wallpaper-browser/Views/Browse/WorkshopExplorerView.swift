import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkshopExplorer: ObservableObject {
  @Published var isPresented = false
  @Published var root: WorkshopExploreRoute = .collections(containing: nil)
  @Published var path: [WorkshopExploreRoute] = []

  func open(_ route: WorkshopExploreRoute) {
    if isPresented {
      guard (path.last ?? root) != route else { return }
      path.append(route)
    } else {
      root = route
      path = []
      isPresented = true
    }
  }

  func back() {
    if path.isEmpty { isPresented = false } else { path.removeLast() }
  }
}

struct WorkshopExplorerView: View {
  @EnvironmentObject private var explorer: WorkshopExplorer
  let showSettings: () -> Void
  let showDownloads: () -> Void

  var body: some View {
    NavigationStack(path: $explorer.path) {
      destination(explorer.root)
        .navigationDestination(for: WorkshopExploreRoute.self) { destination($0) }
    }
    .toolbar(.hidden, for: .windowToolbar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func destination(_ route: WorkshopExploreRoute) -> some View {
    switch route {
    case .item(let item):
      WorkshopExplorerDetail(item: item, showSettings: showSettings, showDownloads: showDownloads)
    case .lookup(let reference):
      WorkshopLookupView(reference: reference, showSettings: showSettings, showDownloads: showDownloads)
    default:
      WorkshopDiscoveryView(route: route, showSettings: showSettings)
    }
  }
}

private struct WorkshopExplorerDetail: View {
  let item: WorkshopItem
  let showSettings: () -> Void
  let showDownloads: () -> Void
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var steamCMD: SteamCMDService
  @Namespace private var transition

  var body: some View {
    WorkshopDetailView(
      item: item, dismiss: { explorer.back() },
      download: {
        guard steamCMD.isInstalled && steamCMD.isLoggedIn else { showSettings(); return }
        if item.isVideo { steamCMD.enqueue(item) }
      },
      showDownloads: showDownloads, setSidebarVisible: { _ in },
      transitionSourceID: "explorer:\(item.id)", transitionNamespace: transition
    )
  }
}

private struct WorkshopLookupView: View {
  let reference: WorkshopReference
  let showSettings: () -> Void
  let showDownloads: () -> Void
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var explorer: WorkshopExplorer
  @State private var resolved: WorkshopExploreRoute?
  @State private var error: String?
  @State private var attempt = 0

  var body: some View {
    Group {
      if let resolved {
        switch resolved {
        case .item(let item):
          WorkshopExplorerDetail(item: item, showSettings: showSettings, showDownloads: showDownloads)
        default:
          WorkshopDiscoveryView(route: resolved, showSettings: showSettings)
        }
      } else if let error {
        ContentUnavailableView {
          Label("browse.loadFailed", systemImage: "exclamationmark.triangle")
        } description: {
          Text(settings.localized(error))
        } actions: {
          Button("explore.back") { explorer.back() }
          Button("common.retry") { attempt += 1 }
          Button("common.openSettings", action: showSettings)
        }
      } else {
        VStack(spacing: 16) {
          ProgressView()
          Button("explore.back") { explorer.back() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: attempt) {
      error = nil
      do {
        let api = WorkshopAPIClient()
        let route: WorkshopExploreRoute
        switch reference {
        case .file(let id):
          let details = try await api.fetchDetails(id: id)
          route = details.item.isCollection
            ? .collection(id: id, title: details.item.title) : .item(details.item)
        case .creator(let id): route = .author(id: id, name: id)
        case .vanity(let name): route = .author(id: try await api.resolveVanity(name), name: name)
        }
        try Task.checkCancellation()
        resolved = route
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }
}

private struct WorkshopDiscoveryView: View {
  let route: WorkshopExploreRoute
  let showSettings: () -> Void
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var favoriteLibrary: FavoriteLibrary
  @State private var items: [WorkshopItem] = []
  @State private var creator: WorkshopCreator?
  @State private var collection: WorkshopDetails?
  @State private var query = ""
  @State private var sort: WorkshopSortOrder = .newest
  @State private var selected: Set<String> = []
  @State private var page = 1
  @State private var childOffset = 0
  @State private var total = 0
  @State private var hasMore = false
  @State private var loading = false
  @State private var error: String?
  @State private var generation = UUID()
  @State private var attempt = 0
  @State private var loadedRequestID: String?
  @State private var isNearBottom = false
  @State private var isVisible = false
  @Namespace private var transition

  private var isAuthor: Bool { if case .author = route { return true }; return false }
  private var isCollection: Bool { if case .collection = route { return true }; return false }
  private var supportsSelection: Bool {
    switch route {
    case .author, .tag, .collection: true
    default: false
    }
  }
  private var title: String {
    switch route {
    case .author(_, let name): creator?.name ?? name
    case .tag(let tag): tag
    case .collections(let id): settings.localized(id == nil ? "explore.collections" : "explore.containing")
    case .collection(_, let title): collection?.item.title ?? title
    default: settings.localized("explore.title")
    }
  }
  private var requestID: String { "\(query)|\(sort.rawValue)|\(attempt)" }
  private var downloadable: [WorkshopItem] { items.filter { $0.isVideo && selected.contains($0.id) } }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Text("explore.title").font(.headline)
        HStack {
          Button { explorer.back() } label: {
            Image(systemName: "chevron.backward").frame(width: 20, height: 20)
          }
          .buttonStyle(.borderless)
          .help("explore.back")
          .keyboardShortcut(.cancelAction)
          Spacer()
        }
      }.padding(.horizontal, 18).frame(height: 48)
      Divider()
      header
      Divider()
      if !isAuthor && !isCollection {
        TextField("browse.searchPrompt", text: $query)
          .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.vertical, 10)
      }
      GeometryReader { viewport in
      ScrollView {
        if let collection, !collection.description.isEmpty {
          WorkshopDescriptionView(text: collection.description).padding(.horizontal, 20).padding(.top, 12)
        }
        if items.isEmpty && !loading && error == nil {
          ContentUnavailableView("explore.empty", systemImage: "square.grid.2x2")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 310), spacing: 16)], spacing: 20) {
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 8) {
              if item.isCollection {
                VStack(alignment: .leading, spacing: 8) {
                  ZStack(alignment: .topTrailing) {
                    Button { explorer.open(.collection(id: item.id, title: item.title)) } label: {
                      Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { WorkshopPreviewImage(url: item.previewURL) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Button { toggleCollection(item) } label: {
                      Image(systemName: favoriteLibrary.containsCollection(item.id) ? "star.fill" : "star")
                        .foregroundStyle(favoriteLibrary.containsCollection(item.id) ? .yellow : .primary)
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(9)
                    .help(favoriteLibrary.containsCollection(item.id) ? "favorites.removeCollection" : "favorites.addCollection")
                  }
                  Button { explorer.open(.collection(id: item.id, title: item.title)) } label: {
                    Label(item.title, systemImage: "square.stack").lineLimit(2)
                  }
                  .buttonStyle(.plain)
                }
              } else {
                WorkshopGridItem(
                  item: item, previewRefreshToken: 0,
                  transitionSourceID: "discovery:\(item.id)", transitionNamespace: transition,
                  isTransitionSource: true, record: steamCMD.record(for: item.id),
                  hasDownloaded: steamCMD.hasDownloaded(item.id),
                  showDetails: { explorer.open(.item(item)) }, download: { download([item]) },
                  retry: { steamCMD.retry(item.id) },
                  isSelected: supportsSelection && item.isVideo ? selected.contains(item.id) : nil,
                  toggleSelection: {
                    if selected.contains(item.id) { selected.remove(item.id) }
                    else { selected.insert(item.id) }
                  }
                )
              }
            }
          }
        }
        .padding(20)
        if loading { ProgressView().padding() }
        if let error {
          HStack {
            Text(settings.localized(error)).foregroundStyle(.secondary)
            Button("common.retry") {
              if items.isEmpty { attempt += 1 } else { Task { await loadMore() } }
            }
            if error == "api.error.missingKey" || error == "api.error.invalidKey" {
              Button("common.openSettings", action: showSettings)
            }
          }.padding()
        }
        Color.clear
          .frame(height: 1)
          .background {
            GeometryReader { marker in
              Color.clear.preference(
                key: WorkshopPaginationBottomKey.self,
                value: marker.frame(in: .named("workshopDiscoveryScroll")).minY
              )
            }
          }
      }
      .coordinateSpace(name: "workshopDiscoveryScroll")
      .onPreferenceChange(WorkshopPaginationBottomKey.self) { bottom in
        isNearBottom = bottom < viewport.size.height + 500
      }
      }
    }
    .onChange(of: isNearBottom) { _, _ in loadIfNearBottom() }
    .onChange(of: loading) { _, isLoading in
      if !isLoading { loadIfNearBottom() }
    }
    .navigationTitle("")
    .navigationBarBackButtonHidden(true)
    .task(id: requestID) {
      isVisible = true
      if loadedRequestID == requestID && !items.isEmpty {
        loading = false
        loadIfNearBottom()
        return
      }
      loadedRequestID = requestID
      generation = UUID()
      let token = generation
      loading = true
      items = []; selected = []; creator = nil; collection = nil
      total = 0; page = 1; childOffset = 0; hasMore = false; error = nil
      do {
        if !query.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
        if case .author(let id, _) = route {
          let profile = try? await WorkshopAPIClient().fetchCreator(id: id)
          guard !Task.isCancelled, token == generation else { return }
          creator = profile
          favoriteLibrary.refreshAuthor(id: id, fallbackName: title, creator: profile)
        }
        if case .collection(let id, _) = route {
          let detail = try await WorkshopAPIClient().fetchDetails(id: id)
          guard !Task.isCancelled, token == generation else { return }
          collection = detail
          total = detail.childIDs.count
          favoriteLibrary.refreshCollection(detail)
        }
        guard !Task.isCancelled, token == generation else { return }
        loading = false
        await loadMore()
      } catch {
        guard !Task.isCancelled, token == generation else { return }
        self.error = error.localizedDescription
        loading = false
      }
    }
    .onDisappear { isVisible = false; generation = UUID() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        if let avatar = creator?.avatarURL {
          AsyncImage(url: avatar) { image in image.resizable() } placeholder: { Color.secondary.opacity(0.15) }
            .frame(width: 48, height: 48).clipShape(Circle())
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.title2.bold()).lineLimit(2).textSelection(.enabled)
          if isAuthor { Text("explore.authorWorks").font(.caption).foregroundStyle(.secondary) }
          if isCollection { Text("explore.collectionWorks").font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        if isAuthor || isCollection {
          Button(action: toggleCurrentFavorite) {
            Label(
              currentFavoriteLabel,
              systemImage: isCurrentFavorite ? "star.fill" : "star"
            )
          }
          .buttonStyle(.bordered)
          .help(currentFavoriteLabel)
        }
        if let url = creator?.profileURL ?? collection?.item.workshopPageURL {
          Link(destination: url) { Image(systemName: "arrow.up.right.square") }
            .help("home.openInWorkshop")
        }
        if !isCollection {
          Picker("common.sort", selection: $sort) {
            ForEach(isAuthor ? [.newest, .highestRated] : WorkshopSortOrder.allCases) { order in
              Text(settings.localized(order.localizationKey)).tag(order)
            }
          }.labelsHidden().frame(width: 155)
        }
      }
      HStack {
        Text(isCollection
          ? settings.localized("explore.memberCount|\(items.count)|\(total)")
          : "\(items.count) / \(total)")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if supportsSelection {
          Button("explore.selectLoaded") { selected = Set(items.filter(\.isVideo).map(\.id)) }
          Button("common.clearAll") { selected = [] }.disabled(selected.isEmpty)
          Button(settings.localized("explore.downloadSelected|\(downloadable.count)")) { download(downloadable) }
            .buttonStyle(.borderedProminent).disabled(downloadable.isEmpty)
        }
      }
    }.padding(20)
  }

  private func download(_ candidates: [WorkshopItem]) {
    guard steamCMD.isInstalled && steamCMD.isLoggedIn else { showSettings(); return }
    for item in candidates where item.isVideo { steamCMD.enqueue(item) }
  }

  private var isCurrentFavorite: Bool {
    switch route {
    case .author(let id, _): favoriteLibrary.containsAuthor(id)
    case .collection(let id, _): favoriteLibrary.containsCollection(id)
    default: false
    }
  }

  private var currentFavoriteLabel: LocalizedStringKey {
    switch (isAuthor, isCurrentFavorite) {
    case (true, true): "favorites.removeAuthor"
    case (true, false): "favorites.addAuthor"
    case (false, true): "favorites.removeCollection"
    default: "favorites.addCollection"
    }
  }

  private func toggleCurrentFavorite() {
    switch route {
    case .author(let id, let routeName):
      favoriteLibrary.toggleAuthor(id: id, name: creator?.name ?? routeName, creator: creator)
    case .collection(let id, let routeTitle):
      favoriteLibrary.toggleCollection(
        id: id,
        title: collection?.item.title ?? routeTitle,
        previewURL: collection?.item.previewURL,
        creatorName: collection?.item.creatorName,
        memberCount: collection?.childIDs.count
      )
    default:
      break
    }
  }

  private func toggleCollection(_ item: WorkshopItem) {
    favoriteLibrary.toggleCollection(
      id: item.id,
      title: item.title,
      previewURL: item.previewURL,
      creatorName: item.creatorName
    )
  }

  private func loadIfNearBottom() {
    guard isVisible, isNearBottom, hasMore, !loading, error == nil,
      loadedRequestID == requestID else { return }
    Task {
      guard isVisible, isNearBottom, hasMore, error == nil, loadedRequestID == requestID else { return }
      await loadMore()
    }
  }

  private func loadMore() async {
    guard !loading, isVisible else { return }
    let token = generation
    loading = true; error = nil
    defer { if token == generation { loading = false } }
    do {
      let newItems: [WorkshopItem]
      let nextHasMore: Bool
      let nextTotal: Int
      let nextOffset: Int
      if let collection {
        let ids = Array(collection.childIDs.dropFirst(childOffset).prefix(30))
        let details = try await WorkshopAPIClient().fetchDetails(ids: ids)
        let byID = Dictionary(details.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        newItems = ids.compactMap { byID[$0] }.filter { $0.fileType == 0 || $0.isCollection }
        nextOffset = childOffset + ids.count
        nextHasMore = nextOffset < collection.childIDs.count
        nextTotal = collection.childIDs.count
      } else {
        let result = try await WorkshopAPIClient().fetchDiscovery(route: route, page: page, query: query, sort: sort)
        newItems = result.items; nextHasMore = result.hasMore; nextTotal = result.total; nextOffset = 0
      }
      guard !Task.isCancelled, token == generation else { return }
      var seen = Set(items.map(\.id))
      items.append(contentsOf: newItems.filter { seen.insert($0.id).inserted })
      total = nextTotal; hasMore = nextHasMore; childOffset = nextOffset; page += 1
    } catch {
      guard !Task.isCancelled, token == generation else { return }
      self.error = error.localizedDescription
    }
  }
}


private struct WorkshopPaginationBottomKey: PreferenceKey {
  static var defaultValue: CGFloat { .infinity }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = min(value, nextValue())
  }
}
