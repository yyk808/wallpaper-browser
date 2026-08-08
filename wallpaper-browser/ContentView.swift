import SwiftUI

private enum SidebarDestination: String, Hashable {
  case workshop
  case downloads
  case settings
}

struct ContentView: View {
  @EnvironmentObject private var browseViewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  @State private var selection: SidebarDestination? = .workshop

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("nav.wallpapers") {
          Label("nav.workshop", systemImage: "square.grid.2x2")
            .tag(SidebarDestination.workshop)
          Label("nav.downloads", systemImage: "arrow.down.circle")
            .badge(steamCMD.activeDownloadCount)
            .tag(SidebarDestination.downloads)
        }
      }
      .navigationTitle("Wallpaper Browser")
      .safeAreaInset(edge: .bottom) {
        SettingsSidebarEntry(isSelected: selection == .settings) {
          selection = .settings
        }
        .padding(8)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
    } detail: {
      switch selection ?? .workshop {
      case .workshop:
        BrowseView(
          viewModel: browseViewModel,
          showSettings: { selection = .settings }
        )
      case .downloads:
        DownloadsView()
      case .settings:
        SettingsView()
      }
    }
    .frame(minWidth: 820, minHeight: 560)
  }
}

private struct SettingsSidebarEntry: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
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
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
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
    .help(statusHelp)
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
