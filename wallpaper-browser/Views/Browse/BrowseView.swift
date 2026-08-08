import AppKit
import SwiftUI

struct BrowseView: View {
  @ObservedObject var viewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  let showSettings: () -> Void

  @State private var isShowingFilters = false
  @State private var selectedItem: WorkshopItem?
  @State private var scrollPositionID: String?

  private let columns = [
    GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14, alignment: .top)
  ]

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !viewModel.filters.isDefault {
          ActiveFiltersBar(viewModel: viewModel)
          Divider()
        }

        content
      }
      .navigationTitle("nav.workshop")
      .searchable(text: $viewModel.searchText, prompt: "browse.searchPrompt")
      .onChange(of: viewModel.searchText) { _, _ in
        viewModel.scheduleSearch()
      }
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
        if viewModel.items.isEmpty { viewModel.loadCachedOrFetch() }
      }
      .navigationDestination(item: $selectedItem) { item in
        WorkshopDetailView(
          item: item,
          download: { requestDownload(item) }
        )
      }
      .toolbar {
        ToolbarItemGroup {
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
      ScrollView {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(viewModel.items) { item in
            WorkshopGridItem(
              item: item,
              previewRefreshToken: viewModel.previewRefreshToken,
              showDetails: { selectedItem = item },
              download: { requestDownload(item) }
            )
            .id(item.id)
          }

          if viewModel.items.count < viewModel.totalCount {
            Color.clear
              .frame(height: 1)
              .task(id: viewModel.items.count) {
                await viewModel.loadMore()
              }
          }
        }
        .padding(16)
        .scrollTargetLayout()

        if let error = viewModel.errorMessage {
          HStack(spacing: 10) {
            Label(appSettings.localized(error), systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            Button("common.retry") {
              Task { await viewModel.loadMore() }
            }
          }
          .font(.caption)
          .padding(.bottom, 20)
        } else if viewModel.isLoading && !viewModel.items.isEmpty {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
      }
      .scrollPosition(id: $scrollPositionID, anchor: .top)
      .onAppear {
        if scrollPositionID == nil {
          scrollPositionID = viewModel.savedScrollItemID
        }
      }
      .onChange(of: scrollPositionID) { _, itemID in
        viewModel.saveScrollPosition(itemID)
      }
      .overlay(alignment: .bottomTrailing) {
        Text("\(viewModel.items.count) / \(viewModel.totalCount)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(8)
      }
    }
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
}
