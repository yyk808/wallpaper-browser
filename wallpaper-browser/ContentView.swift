import SwiftUI

private enum SidebarDestination: String, Hashable {
  case workshop
  case downloads
}

struct ContentView: View {
  @EnvironmentObject private var browseViewModel: BrowseViewModel
  @EnvironmentObject private var steamCMD: SteamCMDService
  @Environment(\.openSettings) private var openSettings
  @State private var selection: SidebarDestination? = .workshop

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("壁纸") {
          Label("创意工坊", systemImage: "square.grid.2x2")
            .tag(SidebarDestination.workshop)
          Label("下载内容", systemImage: "arrow.down.circle")
            .badge(steamCMD.activeDownloadCount)
            .tag(SidebarDestination.downloads)
        }
      }
      .navigationTitle("Wallpaper Browser")
      .safeAreaInset(edge: .bottom) {
        SettingsSidebarEntry(action: openSettings.callAsFunction)
          .padding(8)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
    } detail: {
      switch selection ?? .workshop {
      case .workshop:
        BrowseView(
          viewModel: browseViewModel,
          showSettings: openSettings.callAsFunction
        )
      case .downloads:
        DownloadsView()
      }
    }
    .frame(minWidth: 820, minHeight: 560)
  }
}

private struct SettingsSidebarEntry: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "gearshape")
          .frame(width: 18)
        Text("设置")
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
      isHovering ? Color.primary.opacity(0.07) : .clear,
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
    if steamCMD.isLoggedIn { return "Steam 已登录，打开设置" }
    if steamCMD.isInstalled { return "SteamCMD 已找到，Steam 未登录" }
    return "SteamCMD 尚未设置"
  }
}
