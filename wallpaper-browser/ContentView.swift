import SwiftUI

private enum SidebarDestination: String, Hashable {
  case featured
  case workshop
  case favorites
  case downloads
  case settings
}

struct ContentView: View {
  @ObservedObject var homeViewModel: WorkshopHomeViewModel
  @ObservedObject var browseViewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var favoriteLibrary: FavoriteLibrary
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: SidebarDestination? = .featured
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @StateObject private var explorer = WorkshopExplorer()
  @State private var visibilityBeforeExploring: NavigationSplitViewVisibility = .all
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $selection) {
        Section("nav.wallpapers") {
          Label("nav.featured", systemImage: "sparkles")
            .tag(SidebarDestination.featured)
          Label("nav.workshop", systemImage: "square.grid.2x2")
            .tag(SidebarDestination.workshop)
          Label("nav.favorites", systemImage: "star")
            .badge(favoriteLibrary.totalCount)
            .tag(SidebarDestination.favorites)
          Label("nav.downloads", systemImage: "arrow.down.circle")
            .badge(steamCMD.activeDownloadCount)
            .tag(SidebarDestination.downloads)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color(nsColor: .windowBackgroundColor))
      .safeAreaInset(edge: .top, spacing: 0) {
        sidebarSearch
          .padding(.horizontal, 12)
          .padding(.top, 8)
          .padding(.bottom, 12)
      }
      .safeAreaInset(edge: .bottom) {
        SettingsSidebarEntry(isSelected: selection == .settings) {
          selection = .settings
        }
        .padding(8)
      }
      .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 204)
    } detail: {
      ZStack {
        mainDestination
          .opacity(explorer.isPresented ? 0 : 1)
          .allowsHitTesting(!explorer.isPresented)
          .accessibilityHidden(explorer.isPresented)
        if explorer.isPresented {
          WorkshopExplorerView(
            showSettings: { explorer.isPresented = false; selection = .settings },
            showDownloads: { explorer.isPresented = false; selection = .downloads }
          )
          .background(Color(nsColor: .windowBackgroundColor))
        }
      }
    }
    .environmentObject(explorer)
    .onChange(of: explorer.isPresented) { _, isExploring in
      if isExploring {
        visibilityBeforeExploring = columnVisibility
        setSidebarVisible(false)
      } else {
        setSidebarVisible(visibilityBeforeExploring != .detailOnly)
      }
    }
    .onChange(of: selection) { _, _ in
      if explorer.isPresented { explorer.isPresented = false }
    }
    .toolbar(explorer.isPresented ? .hidden : .automatic, for: .windowToolbar)
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 940, minHeight: 620)
  }

  @ViewBuilder
  private var mainDestination: some View {
      switch selection ?? .featured {
      case .featured:
        WorkshopHomeView(
          viewModel: homeViewModel,
          showWorkshop: { sortOrder, trendPeriod in
            browseViewModel.applyPreset(
              sortOrder: sortOrder,
              trendPeriod: trendPeriod
            )
            selection = .workshop
          },
          showSettings: { selection = .settings },
          showDownloads: { selection = .downloads },
          setSidebarVisible: setSidebarVisible
        )
      case .workshop:
        BrowseView(
          viewModel: browseViewModel,
          showSettings: { selection = .settings },
          showDownloads: { selection = .downloads },
          setSidebarVisible: setSidebarVisible
        )
      case .favorites:
        FavoritesView(showWorkshop: { selection = .workshop })
      case .downloads:
        DownloadsView()
      case .settings:
        SettingsView()
      }
  }

  private var sidebarSearch: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("explore.searchPrompt", text: Binding(
        get: { browseViewModel.searchText },
        set: { text in
          browseViewModel.searchText = text
          selection = .workshop
          if WorkshopReference(text: text) == nil { browseViewModel.scheduleSearch() }
        }
      ))
      .textFieldStyle(.plain)
      .focused($isSearchFocused)
      .onSubmit {
        if let reference = WorkshopReference(text: browseViewModel.searchText) {
          explorer.open(.lookup(reference))
          browseViewModel.searchText = ""
          browseViewModel.loadCachedOrFetch()
        } else {
          selection = .workshop
          browseViewModel.loadCachedOrFetch()
        }
      }
      .help("explore.searchHelp")
      if !browseViewModel.searchText.isEmpty {
        Button {
          browseViewModel.searchText = ""
          selection = .workshop
          browseViewModel.scheduleSearch()
          isSearchFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("common.clearAll")
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 8)
    .frame(height: 32)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSearchFocused ? Color.accentColor : Color.primary.opacity(0.08))
    }
  }

  private func setSidebarVisible(
    _ isVisible: Bool,
    completion: (() -> Void)? = nil
  ) {
    let targetVisibility: NavigationSplitViewVisibility = isVisible ? .all : .detailOnly
    guard columnVisibility != targetVisibility else {
      completion?()
      return
    }

    if reduceMotion {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        columnVisibility = targetVisibility
      }
      completion?()
    } else {
      let animation = Animation.snappy(duration: 0.44, extraBounce: 0.06)
      withAnimation(animation, completionCriteria: .removed) {
        columnVisibility = targetVisibility
      } completion: {
        completion?()
      }
    }
  }
}

private struct SettingsSidebarEntry: View {
  let isSelected: Bool
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "gearshape")
          .frame(width: 18)
        Text("nav.settings")
        Spacer(minLength: 0)
        SteamSidebarStatus()
      }
      .font(.body)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .frame(height: 36)
    .background(
      isSelected
        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.2)
        : isHovering ? Color.primary.opacity(0.07) : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovering = $0 }
    .help("nav.settings")
  }
}

private struct SteamSidebarStatus: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings

  var body: some View {
    Circle()
      .fill(statusColor)
      .frame(width: 7, height: 7)
      .padding(4)
      .help(statusHelp)
      .accessibilityLabel(statusHelp)
  }

  private var statusColor: Color {
    if steamCMD.isLoggedIn { return .green }
    if steamCMD.isInstalled { return .orange }
    return .secondary
  }

  private var statusHelp: String {
    if steamCMD.isLoggedIn { return appSettings.localized("sidebar.steamLoggedIn") }
    if steamCMD.isInstalled { return appSettings.localized("sidebar.steamInstalled") }
    return appSettings.localized("sidebar.steamNotConfigured")
  }
}
