import AppKit
import SwiftUI

private enum SettingsDestination: String, Hashable {
  case workshop
  case steam
  case storage
  case appearance
  case about
}

struct SettingsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @State private var selection: SettingsDestination = .workshop
  @State private var apiKey = ""
  @State private var hasSavedAPIKey = false
  @State private var apiKeyMessage: String?
  @State private var apiKeySaved = false
  @State private var isShowingLogin = false

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
        Label("settings.about", systemImage: "info.circle")
          .tag(SettingsDestination.about)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 520)
      .padding(.horizontal, 24)
      .padding(.vertical, 14)

      Divider()

      switch selection {
      case .workshop:
        workshopPane
      case .steam:
        steamPane
      case .storage:
        StorageSettingsPane()
      case .appearance:
        appearancePane
      case .about:
        aboutPane
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("nav.settings")
    .onAppear {
      apiKey = CredentialStore.shared.loadAPIKey()
      hasSavedAPIKey = !apiKey.isEmpty
    }
    .sheet(isPresented: $isShowingLogin) {
      SteamLoginView()
        .environmentObject(steamCMD)
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

  private var aboutPane: some View {
    SettingsPane(
      title: "settings.about",
      subtitle: "settings.about.subtitle"
    ) {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .center, spacing: 18) {
          Image(nsImage: applicationIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

          VStack(alignment: .leading, spacing: 6) {
            Text("Wallpaper Browser")
              .font(.title)
              .fontWeight(.semibold)
            Text("about.description")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Divider()

        SettingsSection(title: "about.information") {
          SettingsRow(label: "about.version") {
            Text(appVersion)
              .monospacedDigit()
          }

          SettingsRow(label: "about.build") {
            Text(buildNumber)
              .monospacedDigit()
          }

          SettingsRow(label: "about.commit") {
            Text(commitIdentifier)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
          }
        }

        Divider()

        SettingsSection(title: "about.links") {
          SettingsRow(label: "about.sourceCode") {
            Link(
              "github.com/yyk808/wallpaper-browser",
              destination: URL(string: "https://github.com/yyk808/wallpaper-browser")!
            )
          }

          SettingsRow(label: "about.license") {
            Link(
              "AGPL-3.0-only",
              destination: URL(string: "https://github.com/yyk808/wallpaper-browser/blob/main/LICENSE")!
            )
          }
        }
      }
    }
  }

  private var applicationIcon: NSImage {
    NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon") ?? NSImage()
  }

  private var appVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let value = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return "v1.0.0" }
    return value.hasPrefix("v") ? value : "v\(value)"
  }

  private var buildNumber: String {
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let value = build?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.flatMap { $0.isEmpty ? nil : $0 } ?? "1"
  }

  private var commitIdentifier: String {
    let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String
    let value = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return "unknown" }
    return String(value.prefix(7))
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

          if hasSavedAPIKey {
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

        if steamCMD.isInstalled && !steamCMD.isUsingManagedSteamCMD {
          SettingsRow(label: "") {
            if steamCMD.isInstallingSteamCMD {
              ProgressView(value: steamCMD.steamCMDInstallProgress) {
                Text("steamcmd.installing")
              }
              .frame(width: 180)
            } else {
              Button("steamcmd.switchToManaged", systemImage: "arrow.down.circle") {
                Task { await steamCMD.installSteamCMD() }
              }
            }
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
          .fixedSize(horizontal: false, vertical: true)
        if let error = steamCMD.steamCMDInstallError {
          Text(appSettings.localized(error))
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Spacer()

      if steamCMD.isInstallingSteamCMD {
        ProgressView(value: steamCMD.steamCMDInstallProgress) {
          Text("steamcmd.installing")
        }
        .frame(width: 160)
      } else {
        Button {
          Task { await steamCMD.installSteamCMD() }
        } label: {
          Label("steamcmd.installButton", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func saveAPIKey() {
    do {
      try CredentialStore.shared.saveAPIKey(apiKey)
      hasSavedAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      hasSavedAPIKey = false
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

}

@MainActor
private struct StorageSettingsPane: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @ObservedObject private var imageCache: WorkshopImageCache
  @State private var cacheLimitMB: Int
  @State private var isConfirmingCacheClear = false

  init() {
    let cache = WorkshopImageCache.shared
    _imageCache = ObservedObject(wrappedValue: cache)
    _cacheLimitMB = State(initialValue: cache.maximumSizeMegabytes)
  }

  var body: some View {
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
    .onAppear {
      cacheLimitMB = imageCache.maximumSizeMegabytes
      imageCache.refreshDiskUsage()
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
