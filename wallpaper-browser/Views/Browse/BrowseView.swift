import AppKit
import SwiftUI

struct BrowseView: View {
  @ObservedObject var viewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  let showSettings: () -> Void

  @State private var isShowingFilters = false

  private let columns = [
    GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14, alignment: .top)
  ]

  var body: some View {
    VStack(spacing: 0) {
      if !viewModel.filters.isDefault {
        ActiveFiltersBar(viewModel: viewModel)
        Divider()
      }

      content
    }
    .navigationTitle("创意工坊")
    .searchable(text: $viewModel.searchText, prompt: "搜索视频壁纸")
    .onChange(of: viewModel.searchText) { _, _ in
      viewModel.scheduleSearch()
    }
    .onChange(of: viewModel.sortOrder) { _, _ in
      viewModel.refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: .apiKeyDidChange)) { _ in
      viewModel.refresh()
    }
    .task {
      if viewModel.items.isEmpty { viewModel.refresh() }
    }
    .toolbar {
      ToolbarItemGroup {
        Menu {
          Picker("排序", selection: $viewModel.sortOrder) {
            ForEach(WorkshopSortOrder.allCases) { order in
              Text(order.title).tag(order)
            }
          }
        } label: {
          Label(viewModel.sortOrder.title, systemImage: "arrow.up.arrow.down")
        }
        .help("排序")

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
        .help("筛选")
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
          viewModel.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("刷新")
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.items.isEmpty {
      VStack(spacing: 12) {
        ProgressView()
        Text("正在加载创意工坊…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
      ContentUnavailableView {
        Label("无法加载壁纸", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        if !viewModel.hasAPIKey {
          SettingsLink {
            Text("打开设置")
          }
          .buttonStyle(.borderedProminent)
        } else {
          Button("重试") { viewModel.refresh() }
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
              download: { requestDownload(item) }
            )
          }
        }
        .padding(16)

        if viewModel.canLoadMore {
          Button {
            Task { await viewModel.loadMore() }
          } label: {
            if viewModel.isLoading {
              ProgressView().controlSize(.small)
            } else {
              Text("加载更多")
            }
          }
          .buttonStyle(.bordered)
          .padding(.bottom, 20)
        }
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
