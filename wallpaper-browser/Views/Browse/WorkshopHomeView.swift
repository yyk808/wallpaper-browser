import SwiftUI

struct WorkshopHomeView: View {
  let viewModel: WorkshopHomeViewModel
  @ObservedObject private var trendingViewModel: BrowseViewModel
  @ObservedObject private var newestViewModel: BrowseViewModel
  @ObservedObject private var highestRatedViewModel: BrowseViewModel

  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let showWorkshop: (WorkshopSortOrder, WorkshopTrendPeriod) -> Void
  let showSettings: () -> Void
  let showDownloads: () -> Void
  let setSidebarVisible: (Bool, (() -> Void)?) -> Void

  @State private var selectedItem: WorkshopItem?
  @State private var selectedTransitionSourceID: String?
  @State private var homeScrollPosition: String?
  @State private var isDismissingDetail = false
  @State private var stableHomeWidth: CGFloat = 0
  @Namespace private var detailTransition

  private let columns = [
    GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16, alignment: .top)
  ]

  init(
    viewModel: WorkshopHomeViewModel,
    showWorkshop: @escaping (WorkshopSortOrder, WorkshopTrendPeriod) -> Void,
    showSettings: @escaping () -> Void,
    showDownloads: @escaping () -> Void,
    setSidebarVisible: @escaping (Bool, (() -> Void)?) -> Void
  ) {
    self.viewModel = viewModel
    _trendingViewModel = ObservedObject(wrappedValue: viewModel.trending)
    _newestViewModel = ObservedObject(wrappedValue: viewModel.newest)
    _highestRatedViewModel = ObservedObject(wrappedValue: viewModel.highestRated)
    self.showWorkshop = showWorkshop
    self.showSettings = showSettings
    self.showDownloads = showDownloads
    self.setSidebarVisible = setSidebarVisible
  }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let transitionAlignment: Alignment = isDismissingDetail ? .leading : .trailing
        let canUpdateStableWidth = selectedItem == nil && !isDismissingDetail

        ZStack(alignment: transitionAlignment) {
          homeLayer
            .frame(
              width: homeLayerWidth(for: geometry.size.width),
              height: geometry.size.height
            )
            .opacity(selectedItem == nil ? 1 : 0)
            .allowsHitTesting(selectedItem == nil && !isDismissingDetail)
            .accessibilityHidden(selectedItem != nil || isDismissingDetail)

          if let item = selectedItem {
            WorkshopDetailView(
              item: item,
              dismiss: dismissDetail,
              download: { requestDownload(item) },
              showDownloads: showDownloads,
              setSidebarVisible: { isVisible in
                setSidebarVisible(isVisible, nil)
              },
              transitionSourceID: selectedTransitionSourceID ?? "home-fallback:\(item.id)",
              transitionNamespace: detailTransition
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: transitionAlignment)
        .task(
          id: StableLayoutUpdateID(
            width: geometry.size.width,
            isEnabled: canUpdateStableWidth
          )
        ) {
          guard canUpdateStableWidth else { return }
          await Task.yield()
          guard !Task.isCancelled, selectedItem == nil, !isDismissingDetail else { return }
          updateStableHomeWidth(geometry.size.width)
        }
      }
    }
    .toolbar(selectedItem == nil ? .visible : .hidden, for: .windowToolbar)
  }

  private var homeLayer: some View {
    content
      .navigationTitle("nav.featured")
      .onReceive(NotificationCenter.default.publisher(for: .apiKeyDidChange)) { _ in
        viewModel.refresh()
      }
      .task {
        viewModel.loadCachedOrFetch()
      }
      .toolbar {
        ToolbarItem {
          Button { explorer.open(.collections(containing: nil)) } label: {
            Label("explore.collections", systemImage: "square.stack")
          }.help("explore.collections")
        }
        ToolbarItem {
          Button {
            viewModel.refreshPreviews()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("browse.refreshPreviews")
        }
      }
  }

  private func homeLayerWidth(for availableWidth: CGFloat) -> CGFloat {
    guard stableHomeWidth > 0 else { return availableWidth }
    return min(stableHomeWidth, availableWidth)
  }

  private func updateStableHomeWidth(_ width: CGFloat) {
    guard width > 0, abs(stableHomeWidth - width) > 0.5 else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      stableHomeWidth = width
    }
  }

  @ViewBuilder
  private var content: some View {
    if isInitialLoading {
      VStack(spacing: 12) {
        ProgressView()
        Text("browse.loading")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if allItemsEmpty {
      ContentUnavailableView {
        Label("browse.loadFailed", systemImage: "exclamationmark.triangle")
      } description: {
        Text(appSettings.localized(firstErrorMessage ?? "browse.loadFailed"))
      } actions: {
        if !trendingViewModel.hasAPIKey {
          Button("common.openSettings", action: showSettings)
            .buttonStyle(.borderedProminent)
        } else {
          Button("common.retry") { viewModel.refresh() }
            .buttonStyle(.borderedProminent)
        }
      }
    } else if let featuredSource {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          FeaturedWorkshopItem(
            item: featuredSource.item,
            previewRefreshToken: featuredSource.viewModel.previewRefreshToken,
            transitionSourceID: featuredTransitionSourceID(for: featuredSource.item),
            transitionNamespace: detailTransition,
            isTransitionSource: selectedItem == nil
              || selectedTransitionSourceID != featuredTransitionSourceID(for: featuredSource.item),
            eyebrow: appSettings.localized(featuredSource.sortOrder.localizationKey),
            showDetails: {
              showDetails(
                featuredSource.item,
                sourceID: featuredTransitionSourceID(for: featuredSource.item)
              )
            },
            download: { requestDownload(featuredSource.item) }
          )
          .id("home-featured")

          WorkshopHomeSection(
            title: appSettings.localized(WorkshopSortOrder.trending.localizationKey),
            items: sectionItems(for: trendingViewModel, sortOrder: .trending),
            previewRefreshToken: trendingViewModel.previewRefreshToken,
            isLoading: trendingViewModel.isLoading,
            errorMessage: trendingViewModel.errorMessage,
            columns: columns,
            transitionScope: "trending",
            transitionNamespace: detailTransition,
            activeTransitionSourceID: selectedItem == nil ? nil : selectedTransitionSourceID,
            showAll: { showWorkshop(.trending, .week) },
            showDetails: showDetails,
            download: requestDownload
          )
          .id("home-section:trending")

          WorkshopHomeSection(
            title: appSettings.localized(WorkshopSortOrder.newest.localizationKey),
            items: sectionItems(for: newestViewModel, sortOrder: .newest),
            previewRefreshToken: newestViewModel.previewRefreshToken,
            isLoading: newestViewModel.isLoading,
            errorMessage: newestViewModel.errorMessage,
            columns: columns,
            transitionScope: "newest",
            transitionNamespace: detailTransition,
            activeTransitionSourceID: selectedItem == nil ? nil : selectedTransitionSourceID,
            showAll: { showWorkshop(.newest, .week) },
            showDetails: showDetails,
            download: requestDownload
          )
          .id("home-section:newest")

          WorkshopHomeSection(
            title: appSettings.localized(WorkshopSortOrder.highestRated.localizationKey),
            items: sectionItems(for: highestRatedViewModel, sortOrder: .highestRated),
            previewRefreshToken: highestRatedViewModel.previewRefreshToken,
            isLoading: highestRatedViewModel.isLoading,
            errorMessage: highestRatedViewModel.errorMessage,
            columns: columns,
            transitionScope: "highest-rated",
            transitionNamespace: detailTransition,
            activeTransitionSourceID: selectedItem == nil ? nil : selectedTransitionSourceID,
            showAll: { showWorkshop(.highestRated, .week) },
            showDetails: showDetails,
            download: requestDownload
          )
          .id("home-section:highest-rated")
        }
        .scrollTargetLayout()
        .padding(18)
      }
      .scrollPosition(id: $homeScrollPosition, anchor: .center)
    } else {
      ContentUnavailableView("browse.loadFailed", systemImage: "photo.on.rectangle")
    }
  }

  private var featuredSource: FeaturedSource? {
    if let item = trendingViewModel.items.first {
      return FeaturedSource(
        item: item,
        viewModel: trendingViewModel,
        sortOrder: .trending
      )
    }
    if let item = newestViewModel.items.first {
      return FeaturedSource(
        item: item,
        viewModel: newestViewModel,
        sortOrder: .newest
      )
    }
    if let item = highestRatedViewModel.items.first {
      return FeaturedSource(
        item: item,
        viewModel: highestRatedViewModel,
        sortOrder: .highestRated
      )
    }
    return nil
  }

  private func sectionItems(
    for model: BrowseViewModel,
    sortOrder: WorkshopSortOrder
  ) -> [WorkshopItem] {
    let items =
      featuredSource?.sortOrder == sortOrder
      ? model.items.dropFirst()
      : model.items[...]
    return Array(items.prefix(3))
  }

  private var allItemsEmpty: Bool {
    viewModel.allModels.allSatisfy(\.items.isEmpty)
  }

  private var isInitialLoading: Bool {
    allItemsEmpty && viewModel.allModels.contains(where: \.isLoading)
  }

  private var firstErrorMessage: String? {
    viewModel.allModels.compactMap(\.errorMessage).first
  }

  private func requestDownload(_ item: WorkshopItem) {
    guard steamCMD.isInstalled, steamCMD.isLoggedIn else {
      showSettings()
      return
    }
    steamCMD.enqueue(item)
  }

  private func featuredTransitionSourceID(for item: WorkshopItem) -> String {
    "home-featured:\(item.id)"
  }

  private func showDetails(_ item: WorkshopItem, sourceID: String) {
    selectedTransitionSourceID = sourceID
    setSidebarVisible(false, nil)
    withAnimation(detailAnimation) {
      selectedItem = item
    }
  }

  private func dismissDetail() {
    guard selectedItem != nil, !isDismissingDetail else { return }
    isDismissingDetail = true
    setSidebarVisible(true, nil)
    withAnimation(detailAnimation) {
      selectedItem = nil
    }
    Task { @MainActor in
      try? await Task.sleep(for: detailDismissalResetDelay)
      guard selectedItem == nil else { return }
      isDismissingDetail = false
    }
  }

  private var detailAnimation: Animation {
    reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.44, extraBounce: 0.06)
  }

  private var detailDismissalResetDelay: Duration {
    reduceMotion ? .milliseconds(180) : .milliseconds(480)
  }
}

private struct StableLayoutUpdateID: Equatable {
  let width: CGFloat
  let isEnabled: Bool
}

private struct FeaturedSource {
  let item: WorkshopItem
  let viewModel: BrowseViewModel
  let sortOrder: WorkshopSortOrder
}

private struct WorkshopHomeSection: View {
  let title: String
  let items: [WorkshopItem]
  let previewRefreshToken: Int
  let isLoading: Bool
  let errorMessage: String?
  let columns: [GridItem]
  let transitionScope: String
  let transitionNamespace: Namespace.ID
  let activeTransitionSourceID: String?
  let showAll: () -> Void
  let showDetails: (WorkshopItem, String) -> Void
  let download: (WorkshopItem) -> Void

  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var steamCMD: SteamCMDService

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Button(action: showAll) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
          Spacer()
          Text("home.viewAll")
            .font(.subheadline)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("home.openInWorkshop")

      if !items.isEmpty {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
          ForEach(items) { item in
            let sourceID = "home-\(transitionScope):\(item.id)"
            WorkshopGridItem(
              item: item,
              previewRefreshToken: previewRefreshToken,
              transitionSourceID: sourceID,
              transitionNamespace: transitionNamespace,
              isTransitionSource: activeTransitionSourceID != sourceID,
              record: steamCMD.record(for: item.id),
              hasDownloaded: steamCMD.hasDownloaded(item.id),
              showDetails: { showDetails(item, sourceID) },
              download: { download(item) },
              retry: { steamCMD.retry(item.id) }
            )
            .equatable()
            .id(item.id)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .frame(height: 80)
      } else if let errorMessage {
        Label(appSettings.localized(errorMessage), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .frame(height: 80)
      }
    }
  }
}
