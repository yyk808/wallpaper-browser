import AppKit
import SwiftUI

private enum SettingsDestination: String, Hashable {
  case workshop
  case steam
  case storage
}

struct SettingsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @State private var selection: SettingsDestination = .workshop
  @State private var apiKey = ""
  @State private var apiKeyMessage: String?
  @State private var apiKeySaved = false
  @State private var isShowingLogin = false
  @State private var copiedInstallCommand = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("设置分类", selection: $selection) {
        Label("创意工坊", systemImage: "key.horizontal")
          .tag(SettingsDestination.workshop)
        Label("Steam", systemImage: "gamecontroller")
          .tag(SettingsDestination.steam)
        Label("存储", systemImage: "externaldrive")
          .tag(SettingsDestination.storage)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 430)
      .padding(.horizontal, 24)
      .padding(.vertical, 14)

      Divider()

      switch selection {
      case .workshop:
        workshopPane
      case .steam:
        steamPane
      case .storage:
        storagePane
      }
    }
    .frame(minWidth: 720, minHeight: 480)
    .onAppear {
      apiKey = CredentialStore.shared.loadAPIKey()
    }
    .sheet(isPresented: $isShowingLogin) {
      SteamLoginView()
        .environmentObject(steamCMD)
    }
  }

  private var workshopPane: some View {
    SettingsPane(
      title: "创意工坊",
      subtitle: "用于搜索和浏览 Wallpaper Engine 的 Video 类型内容。"
    ) {
      SettingsSection(title: "Steam Web API") {
        SettingsRow(label: "API Key") {
          SecureField("输入 API Key", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 330)

          Button {
            saveAPIKey()
          } label: {
            Label("保存", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        SettingsRow(label: "") {
          Link(
            "获取 Steam Web API Key",
            destination: URL(string: "https://steamcommunity.com/dev/apikey")!
          )

          if !CredentialStore.shared.loadAPIKey().isEmpty {
            Button("移除", systemImage: "trash", role: .destructive) {
              removeAPIKey()
            }
          }
        }

        if let apiKeyMessage {
          SettingsRow(label: "") {
            Label(
              apiKeyMessage,
              systemImage: apiKeySaved ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(apiKeySaved ? .green : .red)
          }
        }
      }
    }
  }

  private var steamPane: some View {
    SettingsPane(
      title: "Steam",
      subtitle: "管理 SteamCMD 路径和用于下载创意工坊内容的账户。"
    ) {
      if !steamCMD.isInstalled {
        installCallout
      }

      SettingsSection(title: "SteamCMD") {
        SettingsRow(label: "状态") {
          StatusValue(
            title: steamCMD.isInstalled ? "已找到" : "未找到",
            color: steamCMD.isInstalled ? .green : .secondary
          )
        }

        SettingsRow(label: "路径") {
          Text(steamCMD.steamCMDPath ?? "未设置")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        SettingsRow(label: "") {
          Button("重新检测", systemImage: "arrow.clockwise") {
            steamCMD.detectSteamCMD()
          }
          Button("选择可执行文件", systemImage: "doc.badge.gearshape") {
            chooseSteamCMD()
          }
        }
      }

      Divider()

      SettingsSection(title: "Steam 账户") {
        SettingsRow(label: "账户") {
          StatusValue(
            title: steamCMD.isLoggedIn ? steamCMD.username : "未登录",
            color: steamCMD.isLoggedIn ? .green : .orange
          )
        }

        SettingsRow(label: "") {
          Button {
            isShowingLogin = true
          } label: {
            Label(
              steamCMD.isLoggedIn ? "管理账户" : "登录 Steam",
              systemImage: steamCMD.isLoggedIn
                ? "person.crop.circle.badge.checkmark" : "person.badge.key"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(!steamCMD.isInstalled)
        }
      }
    }
  }

  private var storagePane: some View {
    SettingsPane(
      title: "存储",
      subtitle: "SteamCMD 下载完成后，主视频文件会被提取到这里。"
    ) {
      SettingsSection(title: "视频目录") {
        SettingsRow(label: "保存到") {
          Text(steamCMD.libraryDirectory.path)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        SettingsRow(label: "") {
          Button("选择目录", systemImage: "folder.badge.plus") {
            chooseLibraryDirectory()
          }
          Button("在 Finder 中显示", systemImage: "folder") {
            revealLibraryDirectory()
          }
        }
      }
    }
  }

  private var installCallout: some View {
    HStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.title2)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 3) {
        Text("未找到 SteamCMD")
          .fontWeight(.medium)
        Text("可使用 Homebrew 安装，或在下方选择已有可执行文件。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text("brew install steamcmd")
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install steamcmd", forType: .string)
        copiedInstallCommand = true
      } label: {
        Image(systemName: copiedInstallCommand ? "checkmark" : "doc.on.doc")
      }
      .help("复制安装命令")
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func saveAPIKey() {
    do {
      try CredentialStore.shared.saveAPIKey(apiKey)
      apiKeyMessage = "已安全保存到钥匙串"
      apiKeySaved = true
    } catch {
      apiKeyMessage = error.localizedDescription
      apiKeySaved = false
    }
  }

  private func removeAPIKey() {
    do {
      try CredentialStore.shared.deleteAPIKey()
      apiKey = ""
      apiKeyMessage = "API Key 已移除"
      apiKeySaved = true
    } catch {
      apiKeyMessage = error.localizedDescription
      apiKeySaved = false
    }
  }

  private func chooseSteamCMD() {
    let panel = NSOpenPanel()
    panel.title = "选择 SteamCMD"
    panel.message = "请选择 steamcmd 或 steamcmd.sh 可执行文件"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      steamCMD.setCustomPath(url.path)
    }
  }

  private func chooseLibraryDirectory() {
    let panel = NSOpenPanel()
    panel.title = "选择视频保存目录"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      steamCMD.setLibraryDirectory(url)
    }
  }

  private func revealLibraryDirectory() {
    try? FileManager.default.createDirectory(
      at: steamCMD.libraryDirectory,
      withIntermediateDirectories: true
    )
    NSWorkspace.shared.open(steamCMD.libraryDirectory)
  }
}

private struct SettingsPane<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  init(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 5) {
          Text(title)
            .font(.title2)
            .fontWeight(.semibold)
          Text(subtitle)
            .foregroundStyle(.secondary)
        }

        Divider()
        content
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.headline)
      content
    }
  }
}

private struct SettingsRow<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  init(label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 82, alignment: .trailing)
      HStack(spacing: 10) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct StatusValue: View {
  let title: String
  let color: Color

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
    }
  }
}
