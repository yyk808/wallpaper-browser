import AppKit
import SwiftUI

struct BrowseView: View {
  @ObservedObject var viewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let showSettings: () -> Void
  let showDownloads: () -> Void
  let setSidebarVisible: (Bool, (() -> Void)?) -> Void

  @State private var isShowingFilters = false
  @State private var isShowingJump = false
  @State private var selectedItem: WorkshopItem?
  @State private var selectedTransitionSourceID: String?
  @State private var lastPaginationTriggerItemID: String?
  @State private var isDismissingDetail = false
  @State private var stableBrowseWidth: CGFloat = 0
  @Namespace private var detailTransition

  private let columns = [
    GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16, alignment: .top)
  ]

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let transitionAlignment: Alignment = isDismissingDetail ? .leading : .trailing
        let canUpdateStableWidth = selectedItem == nil && !isDismissingDetail

        ZStack(alignment: transitionAlignment) {
          browseLayer
            .frame(
              width: browseLayerWidth(for: geometry.size.width),
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
              transitionSourceID: selectedTransitionSourceID ?? transitionSourceID(for: item),
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
          updateStableBrowseWidth(geometry.size.width)
        }
      }
    }
    .toolbar(selectedItem == nil ? .visible : .hidden, for: .windowToolbar)
  }

  private var browseLayer: some View {
    VStack(spacing: 0) {
      if !viewModel.filters.isDefault {
        ActiveFiltersBar(viewModel: viewModel)
        Divider()
      }

      content
    }
    .navigationTitle("nav.workshop")
    .onChange(of: viewModel.sortOrder) { _, _ in
      viewModel.loadCachedOrFetch()
    }
    .onChange(of: viewModel.trendPeriod) { _, _ in
      viewModel.loadCachedOrFetch()
    }
    .onReceive(NotificationCenter.default.publisher(for: .apiKeyDidChange)) { _ in
      viewModel.refresh()
    }
    .task {
      if viewModel.items.isEmpty && !viewModel.isLoading {
        viewModel.loadCachedOrFetch()
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button { explorer.open(.collections(containing: nil)) } label: {
          Label("explore.collections", systemImage: "square.stack")
        }
        .help("explore.collections")
        Menu {
          ForEach(WorkshopSortOrder.allCases) { order in
            Button {
              viewModel.sortOrder = order
            } label: {
              if viewModel.sortOrder == order {
                Label(appSettings.localized(order.localizationKey), systemImage: "checkmark")
              } else {
                Text(appSettings.localized(order.localizationKey))
              }
            }
          }

          if viewModel.sortOrder == .trending {
            Divider()
            Section("browse.trendPeriod") {
              ForEach(WorkshopTrendPeriod.allCases) { period in
                Button {
                  viewModel.trendPeriod = period
                } label: {
                  if viewModel.trendPeriod == period {
                    Label(appSettings.localized(period.localizationKey), systemImage: "checkmark")
                  } else {
                    Text(appSettings.localized(period.localizationKey))
                  }
                }
              }
            }
          }
        } label: {
          Label(sortMenuTitle, systemImage: "arrow.up.arrow.down")
        }
        .help("common.sort")

        Button {
          isShowingFilters.toggle()
        } label: {
          Image(systemName: "line.3.horizontal.decrease")
            .overlay(alignment: .topTrailing) {
              if viewModel.filters.activeCount > 0 {
                Text("\(viewModel.filters.activeCount)")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(minWidth: 13, minHeight: 13)
                  .background(Color.accentColor, in: Circle())
                  .offset(x: 7, y: -6)
              }
            }
        }
        .help("common.filter")
        .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
          FilterPopover(
            filters: viewModel.filters,
            onCancel: { isShowingFilters = false },
            onApply: {
              viewModel.applyFilters($0)
              isShowingFilters = false
            }
          )
        }

        Button {
          viewModel.refreshPreviews()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("browse.refreshPreviews")
      }
    }
  }

  private func browseLayerWidth(for availableWidth: CGFloat) -> CGFloat {
    guard stableBrowseWidth > 0 else { return availableWidth }
    return min(stableBrowseWidth, availableWidth)
  }

  private func updateStableBrowseWidth(_ width: CGFloat) {
    guard width > 0, abs(stableBrowseWidth - width) > 0.5 else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      stableBrowseWidth = width
    }
  }

  private var sortMenuTitle: String {
    let sortTitle = appSettings.localized(viewModel.sortOrder.localizationKey)
    guard viewModel.sortOrder == .trending else { return sortTitle }
    return "\(sortTitle) · \(appSettings.localized(viewModel.trendPeriod.localizationKey))"
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.items.isEmpty {
      VStack(spacing: 12) {
        ProgressView()
        Text("browse.loading")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
      ContentUnavailableView {
        Label("browse.loadFailed", systemImage: "exclamationmark.triangle")
      } description: {
        Text(appSettings.localized(error))
      } actions: {
        if !viewModel.hasAPIKey {
          Button("common.openSettings", action: showSettings)
            .buttonStyle(.borderedProminent)
        } else {
          Button("common.retry") { viewModel.refresh() }
            .buttonStyle(.borderedProminent)
        }
      }
    } else if viewModel.items.isEmpty {
      ContentUnavailableView.search(text: viewModel.searchText)
    } else {
      let scrollSession = viewModel.scrollSessionID
      ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
          ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
            let sourceID = transitionSourceID(for: item)
            WorkshopGridItem(
              item: item,
              previewRefreshToken: viewModel.previewRefreshToken,
              transitionSourceID: sourceID,
              transitionNamespace: detailTransition,
              isTransitionSource: selectedItem == nil || selectedTransitionSourceID != sourceID,
              record: steamCMD.record(for: item.id),
              hasDownloaded: steamCMD.hasDownloaded(item.id),
              showDetails: { showDetails(item, sourceID: sourceID) },
              download: { requestDownload(item) },
              retry: { steamCMD.retry(item.id) }
            )
            .equatable()
            .id(item.id)
            .background {
              GeometryReader { geometry in
                let frame = geometry.frame(in: .named(scrollSession))
                Color.clear.preference(
                  key: BrowseFirstVisibleIndex.self,
                  value: frame.maxY > 0 && frame.width > 0 ? index : Int.max
                )
              }
            }
            .onAppear {
              guard
                item.id == viewModel.items.last?.id,
                lastPaginationTriggerItemID != item.id
              else { return }
              lastPaginationTriggerItemID = item.id
              Task { await viewModel.loadMore() }
            }
          }
        }
        .scrollTargetLayout()
        .padding(18)

        paginationFooter
      }
      .coordinateSpace(name: scrollSession)
      .onPreferenceChange(BrowseFirstVisibleIndex.self) { index in
        guard selectedItem == nil, !isDismissingDetail,
          viewModel.items.indices.contains(index) else { return }
        let id = viewModel.items[index].id
        Task { @MainActor in
          await Task.yield()
          viewModel.rememberVisibleItem(id, session: scrollSession)
        }
      }
      .id(scrollSession)
      .overlay(alignment: .bottomTrailing) {
        VStack(alignment: .trailing, spacing: 8) {
          if isShowingJump {
            BrowseJumpPanel(totalCount: viewModel.totalCount, initialNumber: viewModel.currentItemNumber) { number in
              isShowingJump = false
              lastPaginationTriggerItemID = nil
              viewModel.jump(to: number)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .shadow(radius: 8, y: 3)
          }
          BrowsePositionButton(position: viewModel.position, totalCount: viewModel.totalCount) {
            isShowingJump.toggle()
          }
        }
        .padding(10)
      }
      .onDisappear { viewModel.preserveScrollTarget(session: scrollSession) }
      .task(id: scrollSession) {
        lastPaginationTriggerItemID = nil
        isShowingJump = false
        guard let target = viewModel.initialScrollTargetID else { return }
        await Task.yield()
        guard !Task.isCancelled, scrollSession == viewModel.scrollSessionID else { return }
        proxy.scrollTo(target, anchor: .top)
      }
      }
    }
  }

  @ViewBuilder
  private var paginationFooter: some View {
    ZStack {
      if let error = viewModel.errorMessage {
        HStack(spacing: 10) {
          Label(appSettings.localized(error), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("common.retry") {
            Task { await viewModel.loadMore() }
          }
        }
        .font(.caption)
      } else if viewModel.isLoading && !viewModel.items.isEmpty {
        ProgressView()
          .controlSize(.small)
      } else {
        Color.clear
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 32)
  }

  private func requestDownload(_ item: WorkshopItem) {
    guard steamCMD.isInstalled else {
      showSettings()
      return
    }
    guard steamCMD.isLoggedIn else {
      showSettings()
      return
    }
    steamCMD.enqueue(item)
  }

  private func transitionSourceID(for item: WorkshopItem) -> String {
    "workshop-grid:\(item.id)"
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

struct FeaturedWorkshopItem: View {
  let item: WorkshopItem
  let previewRefreshToken: Int
  let transitionSourceID: String
  let transitionNamespace: Namespace.ID
  let isTransitionSource: Bool
  let eyebrow: String
  let showDetails: () -> Void
  let download: () -> Void

  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.colorScheme) private var colorScheme

  private var record: DownloadRecord? { steamCMD.record(for: item.id) }

  var body: some View {
    GeometryReader { proxy in
      let previewSide = min(342, max(252, proxy.size.width * 0.40))
      let cardBackground = Color(nsColor: .controlBackgroundColor)

      ZStack {
        cardBackground
        ambientPreviewBackground(
          previewSide: previewSide,
          cardBackground: cardBackground
        )

        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
              .font(.headline)
              .foregroundStyle(Color.accentColor)

            Button(action: showDetails) {
              Text(item.title)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            }
            .buttonStyle(.plain)

            let genres = item.genreTags.prefix(3).joined(separator: " · ")
            if !genres.isEmpty {
              Text(genres)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(item.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
              if let rating = item.ratingText {
                Label(rating, systemImage: "star")
              }
              if item.subscriptions > 0 {
                Label(formatCount(item.subscriptions), systemImage: "person.2")
              }
              if item.fileSize > 0 {
                Label(
                  ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                  systemImage: "internaldrive"
                )
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
            if item.isVideo {
              heroAction
            } else {
              Button("detail.view", action: showDetails)
                .buttonStyle(.borderedProminent)
            }
          }
          .padding(28)
          .frame(maxWidth: .infinity, alignment: .leading)

          Button(action: showDetails) {
            WorkshopPreviewImage(
              url: item.previewURL,
              refreshToken: previewRefreshToken
            )
            .frame(width: previewSide, height: previewSide)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .workshopDetailTransitionSource(
              id: transitionSourceID,
              in: transitionNamespace,
              isActive: isTransitionSource
            )
            .padding(4)
          }
          .buttonStyle(.plain)
          .help("detail.view")
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.primary.opacity(0.07), lineWidth: 1)
      }
    }
    .frame(height: 350)
  }

  private func ambientPreviewBackground(
    previewSide: CGFloat,
    cardBackground: Color
  ) -> some View {
    ZStack {
      WorkshopPreviewImage(
        url: item.previewURL,
        refreshToken: previewRefreshToken,
        allowsAnimation: false
      )
      .frame(width: previewSide, height: previewSide)
      .scaleEffect(x: 1.75, y: 1.22, anchor: .trailing)
      .blur(radius: 34)
      .saturation(1.22)
      .opacity(colorScheme == .dark ? 0.52 : 0.32)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
      .mask {
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.30),
            .init(color: .black.opacity(0.16), location: 0.46),
            .init(color: .black.opacity(0.72), location: 0.68),
            .init(color: .black, location: 1.0),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      }

      LinearGradient(
        stops: [
          .init(color: cardBackground, location: 0.0),
          .init(color: cardBackground, location: 0.34),
          .init(color: cardBackground.opacity(0.96), location: 0.46),
          .init(color: cardBackground.opacity(0.72), location: 0.58),
          .init(color: cardBackground.opacity(0.24), location: 0.74),
          .init(color: .clear, location: 0.88),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
    .compositingGroup()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var heroAction: some View {
    switch record?.phase {
    case .queued, .extracting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(record.map { appSettings.localized($0.phase.localizationKey) } ?? "")
      }
      .foregroundStyle(.secondary)
    case .downloading:
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(appSettings.localized(record?.detail ?? "download.detail.downloading"))
        }
        if let progress = record?.progress {
          ProgressView(value: progress, total: 1)
            .frame(maxWidth: 250)
        }
      }
      .foregroundStyle(.secondary)
    case .completed:
      Button {
        if let url = record?.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Label("common.showInFinder", systemImage: "folder")
          .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    case .failed, .cancelled:
      Button {
        steamCMD.retry(item.id)
      } label: {
        Label("download.retry", systemImage: "arrow.clockwise")
          .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    case .none:
      Button(action: download) {
        Label(
          steamCMD.hasDownloaded(item.id) ? "download.again" : "download.video",
          systemImage: "arrow.down"
        )
        .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
  }

  private func formatCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: String(value)
    }
  }
}

private struct BrowseJumpPanel: View {
  let totalCount: Int
  let initialNumber: Int
  let jump: (Int) -> Void
  @State private var numberText = ""
  @FocusState private var isFocused: Bool

  private var number: Int? {
    guard let value = Int(numberText.trimmingCharacters(in: .whitespacesAndNewlines)),
      value > 0, value <= totalCount else { return nil }
    return value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("browse.jump").font(.headline)
      TextField("browse.jumpNumber", text: $numberText)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { if let number { jump(number) } }
      Text("1–\(totalCount)").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("browse.jumpFirst") { jump(1) }
        Spacer()
        Button("browse.jumpGo") { if let number { jump(number) } }
          .buttonStyle(.borderedProminent)
          .disabled(number == nil)
      }
    }
    .padding(16)
    .frame(width: 260)
    .submitScope()
    .onAppear {
      numberText = ""
      isFocused = true
    }
  }
}

private struct BrowseFirstVisibleIndex: PreferenceKey {
  static let defaultValue = Int.max
  static func reduce(value: inout Int, nextValue: () -> Int) {
    value = min(value, nextValue())
  }
}

private struct BrowsePositionButton: View {
  @ObservedObject var position: BrowsePositionState
  let totalCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("\(position.number) / \(totalCount)")
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("browse.jump")
    .font(.caption2)
    .foregroundStyle(.secondary)
  }
}
