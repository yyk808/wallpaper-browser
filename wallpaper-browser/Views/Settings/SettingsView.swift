import AppKit
import SwiftUI

private enum SettingsDestination: String, Hashable {
  case workshop
  case steam
  case storage
  case appearance
}

struct SettingsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @ObservedObject private var imageCache = WorkshopImageCache.shared
  @State private var selection: SettingsDestination = .workshop
  @State private var apiKey = ""
  @State private var apiKeyMessage: String?
  @State private var apiKeySaved = false
  @State private var isShowingLogin = false
  @State private var copiedInstallCommand = false
  @State private var cacheLimitMB = 512
  @State private var isConfirmingCacheClear = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("settings.category", selection: $selection) {
        Label("nav.workshop", systemImage: "key.horizontal")
          .tag(SettingsDestination.workshop)
        Label("Steam", systemImage: "gamecontroller")
          .tag(SettingsDestination.steam)
        Label("settings.storage", systemImage: "externaldrive")
          .tag(SettingsDestination.storage)
        Label("settings.appearance", systemImage: "paintbrush")
          .tag(SettingsDestination.appearance)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 430)
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
      case .appearance:
        appearancePane
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("nav.settings")
    .onAppear {
      apiKey = CredentialStore.shared.loadAPIKey()
      cacheLimitMB = imageCache.maximumSizeMegabytes
      imageCache.refreshDiskUsage()
    }
    .sheet(isPresented: $isShowingLogin) {
      SteamLoginView()
        .environmentObject(steamCMD)
    }
    .confirmationDialog(
      "settings.clearCache.title",
      isPresented: $isConfirmingCacheClear,
      titleVisibility: .visible
    ) {
      Button("settings.clearCache", role: .destructive) {
        imageCache.clear()
      }
      Button("common.cancel", role: .cancel) {}
    } message: {
      Text("settings.clearCache.message")
    }
  }

  private var appearancePane: some View {
    SettingsPane(
      title: "settings.appearance",
      subtitle: "settings.appearance.subtitle"
    ) {
      SettingsSection(title: "settings.language") {
        SettingsRow(label: "settings.appLanguage") {
          Picker("settings.appLanguage", selection: $appSettings.language) {
            ForEach(AppLanguage.allCases) { language in
              Text(appSettings.localized(language.displayName)).tag(language)
            }
          }
          .labelsHidden()
          .frame(width: 180)
        }
      }

      Divider()

      SettingsSection(title: "settings.colorTheme") {
        SettingsRow(label: "settings.theme") {
          Picker("settings.theme", selection: $appSettings.theme) {
            ForEach(AppTheme.allCases) { theme in
              Label(theme.localizedKey, systemImage: theme == .dark ? "moon" : theme == .light ? "sun.max" : "circle.lefthalf.filled")
                .tag(theme)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 260)
        }
      }
    }
  }

  private var workshopPane: some View {
    SettingsPane(
      title: "nav.workshop",
      subtitle: "settings.workshop.subtitle"
    ) {
      SettingsSection(title: "Steam Web API") {
        SettingsRow(label: "API Key") {
          SecureField("settings.apiKey.placeholder", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 330)

          Button {
            saveAPIKey()
          } label: {
            Label("common.save", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        SettingsRow(label: "") {
          Link(
            "settings.apiKey.get",
            destination: URL(string: "https://steamcommunity.com/dev/apikey")!
          )

          if !CredentialStore.shared.loadAPIKey().isEmpty {
            Button("common.remove", systemImage: "trash", role: .destructive) {
              removeAPIKey()
            }
          }
        }

        if let apiKeyMessage {
          SettingsRow(label: "") {
            Label(
              appSettings.localized(apiKeyMessage),
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
      subtitle: "settings.steam.subtitle"
    ) {
      if !steamCMD.isInstalled {
        installCallout
      }

      SettingsSection(title: "SteamCMD") {
        SettingsRow(label: "common.status") {
          StatusValue(
            title: appSettings.localized(steamCMD.isInstalled ? "status.found" : "status.notFound"),
            color: steamCMD.isInstalled ? .green : .secondary
          )
        }

        SettingsRow(label: "common.path") {
          Text(steamCMD.steamCMDPath ?? appSettings.localized("status.notConfigured"))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        SettingsRow(label: "") {
          Button("common.detectAgain", systemImage: "arrow.clockwise") {
            steamCMD.detectSteamCMD()
          }
          Button("settings.chooseExecutable", systemImage: "doc.badge.gearshape") {
            chooseSteamCMD()
          }
        }
      }

      Divider()

      SettingsSection(title: "settings.steamAccount") {
        SettingsRow(label: "common.account") {
          StatusValue(
            title: steamCMD.isLoggedIn ? steamCMD.username : appSettings.localized("status.notSignedIn"),
            color: steamCMD.isLoggedIn ? .green : .orange
          )
        }

        SettingsRow(label: "") {
          Button {
            isShowingLogin = true
          } label: {
            Label(
              steamCMD.isLoggedIn ? "steam.manageAccount" : "steam.signIn",
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
      title: "settings.storage",
      subtitle: "settings.storage.subtitle"
    ) {
      SettingsSection(title: "settings.videoDirectory") {
        SettingsRow(label: "settings.saveTo") {
          Text(steamCMD.libraryDirectory.path)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        SettingsRow(label: "") {
          Button("common.chooseDirectory", systemImage: "folder.badge.plus") {
            chooseLibraryDirectory()
          }
          Button("common.showInFinder", systemImage: "folder") {
            revealLibraryDirectory()
          }
        }
      }

      Divider()

      SettingsSection(title: "settings.previewCache") {
        SettingsRow(label: "settings.used") {
          Text(formatBytes(imageCache.diskUsageBytes))
            .monospacedDigit()
            .frame(minWidth: 72, alignment: .leading)

          ProgressView(
            value: Double(imageCache.diskUsageBytes),
            total: Double(max(imageCache.maximumDiskUsageBytes, 1))
          )
          .progressViewStyle(.linear)
          .frame(maxWidth: 240)
        }

        SettingsRow(label: "settings.limit") {
          Stepper(value: $cacheLimitMB, in: 64...4_096, step: 64) {
            Text("\(cacheLimitMB) MB")
              .monospacedDigit()
              .frame(width: 82, alignment: .leading)
          }
          .onChange(of: cacheLimitMB) { _, value in
            imageCache.setMaximumSize(megabytes: value)
          }
        }

        SettingsRow(label: "") {
          Button("settings.clearCache", systemImage: "trash", role: .destructive) {
            isConfirmingCacheClear = true
          }
          .disabled(imageCache.diskUsageBytes == 0)
        }
      }

      Divider()

      SettingsSection(title: "settings.downloadMetadata") {
        SettingsRow(label: "settings.recorded") {
          Text(
            String(
              format: appSettings.localized("settings.recordedItems"),
              steamCMD.downloadedMetadataCount
            )
          )
            .monospacedDigit()
        }

        SettingsRow(label: "common.status") {
          Label("settings.savedSeparately", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
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
        Text("steamcmd.notFound.title")
          .fontWeight(.medium)
        Text("steamcmd.notFound.message")
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
      .help("steamcmd.copyInstallCommand")
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func saveAPIKey() {
    do {
      try CredentialStore.shared.saveAPIKey(apiKey)
      apiKeyMessage = "settings.apiKey.saved"
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
      apiKeyMessage = "settings.apiKey.removed"
      apiKeySaved = true
    } catch {
      apiKeyMessage = error.localizedDescription
      apiKeySaved = false
    }
  }

  private func chooseSteamCMD() {
    let panel = NSOpenPanel()
    panel.title = "steamcmd.choose.title"
    panel.message = "steamcmd.choose.message"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      steamCMD.setCustomPath(url.path)
    }
  }

  private func chooseLibraryDirectory() {
    let panel = NSOpenPanel()
    panel.title = "settings.chooseVideoDirectory"
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

  private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}

private struct SettingsPane<Content: View>: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  @ViewBuilder let content: Content

  init(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
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
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
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
  let label: LocalizedStringKey
  @ViewBuilder let content: Content

  init(label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
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
