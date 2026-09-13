import AppKit
import AVFoundation
import Combine
import SwiftUI

struct DownloadsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var explorer: WorkshopExplorer
  @StateObject private var videoPreview = VideoPreviewWindowController()
  @State private var selection: Set<String> = []
  @State private var pendingDeletion: Set<String> = []
  @State private var isConfirmingDeletion = false
  @State private var deleteErrorMessage: String?
  @State private var derivedState = DerivedState()

  var body: some View {
    Group {
      if steamCMD.records.isEmpty {
        ContentUnavailableView(
          "downloads.empty.title",
          systemImage: "arrow.down.circle",
          description: Text("downloads.empty.description")
        )
      } else {
        List(selection: $selection) {
          ForEach(steamCMD.records) { record in
            DownloadRow(
              record: record,
              fileIsAvailable: fileAvailability(for: record),
              onQuickLook: {
                selection = [record.id]
                showVideoPreview([record.id])
              },
              onDelete: {
                requestDeletion([record.id])
              },
              onShowDetails: {
                selection = [record.id]
                explorer.open(.item(record.item))
              },
              onCancel: { steamCMD.cancel(record.id) },
              onRetry: { steamCMD.retry(record.id) }
            )
            .equatable()
            .tag(record.id)
          }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
          guard canQuickLook else { return .ignored }
          showVideoPreview()
          return .handled
        }
      }
    }
    .navigationTitle("nav.downloads")
    .onChange(of: recordStructureSignature, initial: true) { _, _ in
      synchronizeRecordStructure()
    }
    .onChange(of: selection) { _, _ in
      synchronizeSelectionAndDeletionState()
    }
    .onChange(of: pendingDeletion) { _, _ in
      synchronizeSelectionAndDeletionState()
    }
    .confirmationDialog(
      deletionTitle,
      isPresented: $isConfirmingDeletion,
      titleVisibility: .visible
    ) {
      Button(deletionActionTitle, role: .destructive) {
        performDeletion()
      }
      Button("common.cancel", role: .cancel) {
        pendingDeletion = []
      }
    } message: {
      Text(deletionMessage)
    }
    .alert(
      "downloads.deleteError.title",
      isPresented: Binding(
        get: { deleteErrorMessage != nil },
        set: { if !$0 { deleteErrorMessage = nil } }
      )
    ) {
      Button("common.ok") { deleteErrorMessage = nil }
    } message: {
      Text(appSettings.localized(deleteErrorMessage ?? ""))
    }
    .toolbar {
      ToolbarItem {
        Button {
          showVideoPreview()
        } label: {
          Image(systemName: "eye")
        }
        .help("downloads.quickLookSpace")
        .disabled(!canQuickLook)
      }
      ToolbarItem {
        Button {
          NSWorkspace.shared.open(steamCMD.libraryDirectory)
        } label: {
          Image(systemName: "folder")
        }
        .help("downloads.openFolder")
      }
      ToolbarItem {
        Button {
          requestDeletion(selection)
        } label: {
          Image(systemName: "trash")
        }
        .help("downloads.trashSelection")
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!canDeleteSelection)
      }
    }
  }

  private var canQuickLook: Bool {
    !derivedState.selectedPreviewURLs.isEmpty
  }

  private var canDeleteSelection: Bool {
    derivedState.canDeleteSelection
  }

  private var deletionTitle: String {
    pendingDeletion.count > 1
      ? String(format: appSettings.localized("downloads.deleteMultipleTitle"), pendingDeletion.count)
      : appSettings.localized("downloads.deleteSelectedTitle")
  }

  private var deletionMessage: String {
    if pendingFileCount > 0 {
      return appSettings.localized("downloads.deleteFilesMessage")
    }
    return appSettings.localized("downloads.deleteRecordMessage")
  }

  private var deletionActionTitle: String {
    appSettings.localized(
      pendingFileCount > 0 ? "downloads.moveToTrash" : "downloads.removeRecord"
    )
  }

  private var pendingFileCount: Int {
    derivedState.pendingFileCount
  }

  private func showVideoPreview(_ ids: Set<String>? = nil) {
    let urls = previewURLs(for: ids ?? selection, revalidate: true)
    guard !urls.isEmpty else { return }
    videoPreview.show(urls: urls, appSettings: appSettings, steamCMD: steamCMD)
  }

  private func requestDeletion(_ ids: Set<String>) {
    pendingDeletion = ids
    refreshFileAvailability(for: ids)
    isConfirmingDeletion = !ids.isEmpty
  }

  private func performDeletion() {
    videoPreview.close()
    let ids = pendingDeletion
    pendingDeletion = []
    deleteErrorMessage = steamCMD.moveRecordsToTrash(ids)
    selection.subtract(ids)
  }

  private var recordStructureSignature: [RecordStructure] {
    steamCMD.records.map {
      RecordStructure(id: $0.id, phase: $0.phase, localPath: $0.localPath)
    }
  }

  private func synchronizeRecordStructure() {
    let records = steamCMD.records
    let orderedIDs = records.map(\.id)
    let recordIDs = Set(orderedIDs)
    let validSelection = selection.intersection(recordIDs)

    var fileAvailabilityByID: [String: Bool] = [:]
    fileAvailabilityByID.reserveCapacity(records.count)
    var previewCandidatesByID: [String: URL] = [:]
    previewCandidatesByID.reserveCapacity(records.count)
    var fileAvailabilityByPath: [String: Bool] = [:]

    for record in records {
      guard let url = record.localURL else {
        fileAvailabilityByID[record.id] = false
        continue
      }

      let isAvailable: Bool
      if let cached = fileAvailabilityByPath[url.path] {
        isAvailable = cached
      } else {
        let checked = FileManager.default.fileExists(atPath: url.path)
        fileAvailabilityByPath[url.path] = checked
        isAvailable = checked
      }
      fileAvailabilityByID[record.id] = isAvailable

      if record.phase == .completed {
        previewCandidatesByID[record.id] = url
      }
    }

    if selection != validSelection {
      selection = validSelection
    }
    derivedState.orderedIDs = orderedIDs
    derivedState.fileAvailabilityByID = fileAvailabilityByID
    derivedState.previewCandidatesByID = previewCandidatesByID
    synchronizeSelectionAndDeletionState()
  }

  private func synchronizeSelectionAndDeletionState() {
    let records = steamCMD.records
    var selectedPreviewURLs: [URL] = []
    var hasSelectedRecord = false
    var canDeleteSelection = true
    var pendingFileCount = 0

    for record in records {
      let isSelected = selection.contains(record.id)
      if isSelected {
        hasSelectedRecord = true
        if [.queued, .downloading, .extracting].contains(record.phase) {
          canDeleteSelection = false
        }
        if record.phase == .completed,
          let url = derivedState.previewCandidatesByID[record.id],
          derivedState.fileAvailabilityByID[record.id] == true
        {
          selectedPreviewURLs.append(url)
        }
      }

      if pendingDeletion.contains(record.id),
        derivedState.fileAvailabilityByID[record.id] == true
      {
        pendingFileCount += 1
      }
    }

    derivedState.selectedPreviewURLs = selectedPreviewURLs
    derivedState.canDeleteSelection = hasSelectedRecord && canDeleteSelection
    derivedState.pendingFileCount = pendingFileCount
  }

  private func previewURLs(for ids: Set<String>, revalidate: Bool) -> [URL] {
    var refreshedAvailability: [String: Bool] = [:]
    var urls: [URL] = []

    for id in derivedState.orderedIDs where ids.contains(id) {
      guard let url = derivedState.previewCandidatesByID[id] else { continue }
      let isAvailable: Bool
      if revalidate {
        let checked = FileManager.default.fileExists(atPath: url.path)
        refreshedAvailability[id] = checked
        isAvailable = checked
      } else {
        isAvailable = derivedState.fileAvailabilityByID[id] == true
      }
      if isAvailable {
        urls.append(url)
      }
    }

    if revalidate && !refreshedAvailability.isEmpty {
      var availabilityChanged = false
      for (id, isAvailable) in refreshedAvailability {
        if derivedState.fileAvailabilityByID[id] != isAvailable {
          availabilityChanged = true
          break
        }
      }
      if availabilityChanged {
        for (id, isAvailable) in refreshedAvailability {
          derivedState.fileAvailabilityByID[id] = isAvailable
        }
        synchronizeSelectionAndDeletionState()
      }
    }
    return urls
  }

  private func fileAvailability(for record: DownloadRecord) -> Bool {
    if let cached = derivedState.fileAvailabilityByID[record.id] {
      return cached
    }
    guard let url = record.localURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private func refreshFileAvailability(for ids: Set<String>) {
    guard !ids.isEmpty else { return }
    var availabilityByPath: [String: Bool] = [:]
    for record in steamCMD.records where ids.contains(record.id) {
      guard let url = record.localURL else {
        derivedState.fileAvailabilityByID[record.id] = false
        continue
      }

      let isAvailable: Bool
      if let cached = availabilityByPath[url.path] {
        isAvailable = cached
      } else {
        let checked = FileManager.default.fileExists(atPath: url.path)
        availabilityByPath[url.path] = checked
        isAvailable = checked
      }
      derivedState.fileAvailabilityByID[record.id] = isAvailable
    }
    synchronizeSelectionAndDeletionState()
  }

  private struct RecordStructure: Equatable {
    let id: String
    let phase: DownloadPhase
    let localPath: String?
  }

  private struct DerivedState {
    var orderedIDs: [String] = []
    var fileAvailabilityByID: [String: Bool] = [:]
    var previewCandidatesByID: [String: URL] = [:]
    var selectedPreviewURLs: [URL] = []
    var canDeleteSelection = false
    var pendingFileCount = 0
  }
}

private struct DownloadRow: View, Equatable {
  @EnvironmentObject private var appSettings: AppSettings
  let record: DownloadRecord
  let fileIsAvailable: Bool
  let onQuickLook: () -> Void
  let onDelete: () -> Void
  let onShowDetails: () -> Void
  let onCancel: () -> Void
  let onRetry: () -> Void

  static func == (lhs: DownloadRow, rhs: DownloadRow) -> Bool {
    lhs.record == rhs.record && lhs.fileIsAvailable == rhs.fileIsAvailable
  }

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Color(nsColor: .controlBackgroundColor)
        WorkshopPreviewImage(url: record.item.previewURL, allowsAnimation: false)
      }
      .frame(width: 112, height: 63)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .contentShape(Rectangle())
      .onTapGesture(count: 2, perform: onShowDetails)
      .help("detail.view")

      VStack(alignment: .leading, spacing: 5) {
        Button(action: onShowDetails) {
          Text(record.item.title)
            .fontWeight(.medium)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("detail.view")
        HStack(spacing: 6) {
          phaseIcon
          Text(appSettings.localized(record.phase.localizationKey))
          if !record.detail.isEmpty {
            Text("·")
            Text(appSettings.localized(record.detail)).lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(record.phase == .failed ? Color.red : Color.secondary)

        if record.phase == .completed && record.needsThirdPartyPlayer {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(appSettings.localized("download.warning.thirdPartyPlayer"))
          }
          .font(.caption)
          .foregroundStyle(.yellow)
          .help("download.warning.thirdPartyPlayer")
        }

        if record.phase == .downloading {
          downloadProgress
        }
      }

      Spacer()
      actions
    }
    .padding(.vertical, 5)
    .contextMenu {
      Button("detail.view", systemImage: "info.circle", action: onShowDetails)
      Divider()
      Button("downloads.quickLook", systemImage: "eye", action: onQuickLook)
        .disabled(!canQuickLook)
      if record.phase == .completed, let url = record.localURL {
        Button("common.showInFinder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
      Divider()
      Button(role: .destructive, action: onDelete) {
        Label(
          record.localURL == nil ? "downloads.removeRecord" : "downloads.moveToTrash",
          systemImage: "trash"
        )
      }
      .disabled([.queued, .downloading, .extracting].contains(record.phase))
    }
  }

  private var canQuickLook: Bool {
    record.phase == .completed && record.localURL != nil && fileIsAvailable
  }

  @ViewBuilder
  private var downloadProgress: some View {
    if let progress = record.progress {
      ProgressView(value: progress, total: 1)
        .progressViewStyle(.linear)

      HStack {
        Text(String(format: "%.0f%%", progress * 100))
        Spacer()
        if let bytesPerSecond = record.bytesPerSecond, bytesPerSecond > 0 {
          Text(formatSpeed(bytesPerSecond))
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    } else {
      ProgressView()
        .progressViewStyle(.linear)
    }
  }

  @ViewBuilder
  private var phaseIcon: some View {
    switch record.phase {
    case .queued, .downloading, .extracting:
      ProgressView().controlSize(.mini)
    case .completed:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
    case .cancelled:
      Image(systemName: "minus.circle").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: 6) {
      Button(action: onShowDetails) {
        Image(systemName: "info.circle")
      }
      .buttonStyle(.borderless)
      .help("detail.view")

      switch record.phase {
      case .queued, .downloading, .extracting:
        Button(action: onCancel) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("common.cancel")
      case .completed:
        Button(action: onQuickLook) {
          Image(systemName: "eye")
        }
        .buttonStyle(.borderless)
        .help("downloads.quickLook")
        .disabled(!canQuickLook)
        Button {
          if let url = record.localURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("common.showInFinder")
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("downloads.moveToTrash")
      case .failed, .cancelled:
        Button(action: onRetry) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("common.retry")
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("downloads.removeRecord")
      }
    }
  }

  private func formatSpeed(_ bytesPerSecond: Double) -> String {
    let formatted = ByteCountFormatter.string(
      fromByteCount: Int64(bytesPerSecond),
      countStyle: .file
    )
    return "\(formatted)/s"
  }
}

@MainActor
private struct VideoPreviewView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @ObservedObject var controller: VideoPreviewController
  @ObservedObject var windowState: VideoPreviewWindowState
  @State private var pointerIsInside = false
  let close: () -> Void
  let toggleFullScreen: () -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        VideoPlayerSurface(
          player: controller.player,
          onHoverChange: { pointerIsInside = $0 },
          onTogglePlayback: controller.togglePlayback
        )

        if controller.isPreparing {
          VStack(spacing: 12) {
            ProgressView()
              .controlSize(.large)
            Text("downloads.preparingVideo")
              .foregroundStyle(.secondary)
          }
        } else if controller.playbackUnavailable {
          ContentUnavailableView {
            Label("downloads.playbackUnavailable", systemImage: "play.slash")
          } description: {
            Text("download.warning.thirdPartyPlayer")
          } actions: {
            Button("common.showInFinder") {
              NSWorkspace.shared.activateFileViewerSelecting([controller.currentURL])
            }
          }
        }

        if showsControls {
          VStack(spacing: 0) {
            HStack {
              previewWindowButton(
                systemImage: "xmark",
                help: "detail.closePreview",
                action: close
              )
              .keyboardShortcut(.cancelAction)

              Spacer()

              previewWindowButton(
                systemImage: windowState.isFullScreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right",
                help: windowState.isFullScreen
                  ? "downloads.exitFullScreen"
                  : "downloads.enterFullScreen",
                action: toggleFullScreen
              )
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer(minLength: 0)

            VideoPlaybackHUD(controller: controller)
              .padding(.horizontal, 10)
              .padding(.bottom, 8)
          }
          .transition(.opacity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .contentShape(Rectangle())
    }
    .background(.black)
    .frame(minWidth: 420, minHeight: 240)
    .ignoresSafeArea(.all)
    .animation(.easeOut(duration: 0.16), value: showsControls)
    .onExitCommand(perform: close)
    .onKeyPress(.leftArrow) {
      controller.seek(to: controller.currentTime - 5)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      controller.seek(to: controller.currentTime + 5)
      return .handled
    }
    .onAppear {
      controller.play()
    }
    .onDisappear {
      controller.stop()
    }
    .onChange(of: controller.repairedSourceURL, initial: true) { _, url in
      if let url {
        steamCMD.markVideoAsSystemPlayable(at: url)
      }
    }
  }

  private var showsControls: Bool {
    pointerIsInside || !controller.isPlaying
  }

  private func previewWindowButton(
    systemImage: String,
    help: LocalizedStringKey,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 30, height: 30)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

@MainActor
private struct VideoPlaybackHUD: View {
  @ObservedObject var controller: VideoPreviewController
  @State private var isSeeking = false
  @State private var seekValue = 0.0

  var body: some View {
    HStack(spacing: 10) {
      Button(action: controller.togglePlayback) {
        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)

      Text(formatTime(displayedTime))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(minWidth: 42, alignment: .trailing)

      Slider(
        value: Binding(
          get: { displayedTime },
          set: { seekValue = $0 }
        ),
        in: 0...max(controller.duration, 0.1),
        onEditingChanged: { editing in
          if editing {
            seekValue = controller.currentTime
            isSeeking = true
          } else {
            controller.seek(to: seekValue)
            isSeeking = false
          }
        }
      )
      .disabled(controller.duration <= 0)

      Text(formatTime(controller.duration))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(minWidth: 42, alignment: .leading)

      Button(action: controller.toggleMuted) {
        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)

      Slider(
        value: Binding(
          get: { controller.volume },
          set: { controller.setVolume($0) }
        ),
        in: 0...1
      )
      .frame(width: 72)
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
  }

  private var displayedTime: Double {
    isSeeking ? seekValue : controller.currentTime
  }

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let value = Int(seconds.rounded(.down))
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let remainingSeconds = value % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
  }
}

@MainActor
private final class VideoPreviewWindowState: ObservableObject {
  @Published var isFullScreen = false
}

private final class VideoPreviewWindow: NSWindow {
  var closeOnSpace: (() -> Void)?

  override func sendEvent(_ event: NSEvent) {
    let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    if event.type == .keyDown,
       event.keyCode == 49,
       !event.isARepeat,
       event.modifierFlags.intersection(blockedModifiers).isEmpty
    {
      closeOnSpace?()
      return
    }
    super.sendEvent(event)
  }
}

@MainActor
private final class VideoPreviewWindowController: NSObject, ObservableObject, NSWindowDelegate {
  private var window: NSWindow?
  private var playbackController: VideoPreviewController?
  private var aspectRatioSubscription: AnyCancellable?
  private var windowState: VideoPreviewWindowState?
  private var isTransitioningFullScreen = false
  private var shouldCloseAfterFullScreen = false

  func show(
    urls: [URL],
    appSettings: AppSettings,
    steamCMD: SteamCMDService
  ) {
    guard !urls.isEmpty else { return }
    if let window {
      if window.isVisible {
        close()
      } else {
        playbackController?.replaceURLs(urls)
        window.center()
        window.makeKeyAndOrderFront(nil)
      }
      return
    }

    let playbackController = VideoPreviewController(urls: urls)
    let windowState = VideoPreviewWindowState()
    let window = VideoPreviewWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.backgroundColor = .black
    window.isOpaque = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: 420, height: 240)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.delegate = self

    let content = VideoPreviewView(
      controller: playbackController,
      windowState: windowState,
      close: { [weak self] in self?.close() },
      toggleFullScreen: { [weak self] in self?.toggleFullScreen() }
    )
    .environmentObject(appSettings)
    .environmentObject(steamCMD)
    .environment(\.locale, appSettings.locale)
    .preferredColorScheme(appSettings.theme.colorScheme)
    window.contentViewController = NSHostingController(rootView: content)

    self.window = window
    self.playbackController = playbackController
    self.windowState = windowState
    window.closeOnSpace = { [weak self] in
      self?.close()
    }
    aspectRatioSubscription = playbackController.$displayAspectRatio
      .compactMap { $0 }
      .removeDuplicates()
      .sink { [weak self] ratio in
        self?.resizeWindow(for: ratio)
      }

    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    guard let window else { return }
    if window.styleMask.contains(.fullScreen) {
      shouldCloseAfterFullScreen = true
      if !isTransitioningFullScreen {
        isTransitioningFullScreen = true
        window.toggleFullScreen(nil)
      }
      return
    }
    if isTransitioningFullScreen {
      shouldCloseAfterFullScreen = true
      return
    }
    hideWindow()
  }

  private func toggleFullScreen() {
    guard !isTransitioningFullScreen else { return }
    isTransitioningFullScreen = true
    window?.toggleFullScreen(nil)
  }

  private func resizeWindow(for aspectRatio: CGFloat) {
    guard let window, !window.styleMask.contains(.fullScreen), aspectRatio > 0 else { return }
    let visibleFrame = window.screen?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maximumWidth = visibleFrame.width * 0.82
    let maximumHeight = visibleFrame.height * 0.82
    var width = min(960, maximumWidth)
    var height = width / aspectRatio
    if height > maximumHeight {
      height = maximumHeight
      width = height * aspectRatio
    }
    window.setContentSize(NSSize(width: width, height: height))
    window.center()
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    windowState?.isFullScreen = true
    finishFullScreenTransition()
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    windowState?.isFullScreen = false
    finishFullScreenTransition()
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    isTransitioningFullScreen = true
  }

  func windowWillExitFullScreen(_ notification: Notification) {
    isTransitioningFullScreen = true
  }

  func windowWillClose(_ notification: Notification) {
    playbackController?.stop()
    aspectRatioSubscription = nil
    playbackController = nil
    windowState = nil
    window = nil
    isTransitioningFullScreen = false
    shouldCloseAfterFullScreen = false
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    close()
    return false
  }

  private func finishFullScreenTransition() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self else { return }
      self.isTransitioningFullScreen = false
      if self.shouldCloseAfterFullScreen {
        if self.window?.styleMask.contains(.fullScreen) == true {
          self.isTransitioningFullScreen = true
          self.window?.toggleFullScreen(nil)
        } else {
          self.shouldCloseAfterFullScreen = false
          self.hideWindow()
        }
      }
    }
  }

  private func hideWindow() {
    playbackController?.stop()
    window?.orderOut(nil)
  }
}

@MainActor
private final class VideoPreviewController: ObservableObject {
  private(set) var urls: [URL]
  let player = AVPlayer()
  @Published private(set) var currentIndex = 0
  @Published private(set) var isPreparing = true
  @Published private(set) var playbackUnavailable = false
  @Published private(set) var repairedSourceURL: URL?
  @Published private(set) var displayAspectRatio: CGFloat?
  @Published private(set) var currentTime = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var isPlaying = false
  @Published private(set) var isMuted = false
  @Published private(set) var volume = 1.0
  private var preparedPlayback: PreparedVideoPlayback?
  private var preparationTask: Task<Void, Never>?
  private var wantsPlayback = false
  private var timeObserver: Any?

  init(urls: [URL]) {
    precondition(!urls.isEmpty)
    self.urls = urls
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      let seconds = time.seconds
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentTime = seconds.isFinite ? max(0, seconds) : 0
        self.isPlaying = self.player.rate != 0
      }
    }
    prepareCurrentItem(autoplay: false)
  }

  deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
  }

  var currentURL: URL {
    urls[currentIndex]
  }

  var canMoveBackward: Bool {
    currentIndex > 0
  }

  var canMoveForward: Bool {
    currentIndex < urls.count - 1
  }

  func play() {
    wantsPlayback = true
    if player.currentItem != nil {
      player.play()
      isPlaying = true
    }
  }

  func togglePlayback() {
    if isPlaying {
      player.pause()
      wantsPlayback = false
      isPlaying = false
    } else {
      wantsPlayback = true
      if duration > 0, currentTime >= duration - 0.1 {
        seek(to: 0)
      }
      player.play()
      isPlaying = true
    }
  }

  func seek(to seconds: Double) {
    let clamped = min(max(0, seconds), max(duration, 0))
    currentTime = clamped
    player.seek(
      to: CMTime(seconds: clamped, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  func toggleMuted() {
    isMuted.toggle()
    player.isMuted = isMuted
  }

  func setVolume(_ value: Double) {
    volume = min(max(0, value), 1)
    player.volume = Float(volume)
    if volume > 0, isMuted {
      isMuted = false
      player.isMuted = false
    }
  }

  func stop() {
    wantsPlayback = false
    preparationTask?.cancel()
    player.pause()
    isPlaying = false
    player.replaceCurrentItem(with: nil)
    let playback = preparedPlayback
    preparedPlayback = nil
    Task {
      await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: playback)
    }
  }

  func move(by offset: Int) {
    let nextIndex = currentIndex + offset
    guard urls.indices.contains(nextIndex) else { return }
    currentIndex = nextIndex
    prepareCurrentItem(autoplay: true)
  }

  func replaceURLs(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    self.urls = urls
    currentIndex = 0
    repairedSourceURL = nil
    prepareCurrentItem(autoplay: true)
  }

  private func prepareCurrentItem(autoplay: Bool) {
    preparationTask?.cancel()
    player.pause()
    player.replaceCurrentItem(with: nil)
    isPreparing = true
    playbackUnavailable = false
    displayAspectRatio = nil
    currentTime = 0
    duration = 0
    isPlaying = false
    wantsPlayback = autoplay

    let sourceURL = currentURL
    let previousPlayback = preparedPlayback
    preparedPlayback = nil
    preparationTask = Task { [weak self] in
      await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: previousPlayback)
      let metadata = await videoMetadata(for: sourceURL)
      let playback = await VideoPlaybackCompatibility.shared.prepare(sourceURL)
      guard !Task.isCancelled, let self, self.currentURL == sourceURL else {
        await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: playback)
        return
      }

      self.isPreparing = false
      self.displayAspectRatio = metadata.aspectRatio
      self.duration = metadata.duration
      guard let playback else {
        self.playbackUnavailable = true
        return
      }
      self.preparedPlayback = playback
      if playback.repairedSource {
        self.repairedSourceURL = sourceURL
      }
      self.player.replaceCurrentItem(with: AVPlayerItem(url: playback.url))
      if self.wantsPlayback {
        self.player.play()
        self.isPlaying = true
      }
    }
  }
}

private func videoMetadata(for url: URL) async -> (aspectRatio: CGFloat?, duration: Double) {
  let asset = AVURLAsset(url: url)
  let assetDuration = try? await asset.load(.duration)
  let duration = if let seconds = assetDuration?.seconds, seconds.isFinite, seconds > 0 {
    seconds
  } else {
    0.0
  }
  guard let tracks = try? await asset.loadTracks(withMediaType: .video),
    let track = tracks.first,
    let naturalSize = try? await track.load(.naturalSize),
    let transform = try? await track.load(.preferredTransform)
  else { return (nil, duration) }

  let displaySize = CGRect(origin: .zero, size: naturalSize)
    .applying(transform)
    .standardized.size
  guard displaySize.width > 0, displaySize.height > 0 else { return (nil, duration) }
  return (displaySize.width / displaySize.height, duration)
}

private struct VideoPlayerSurface: NSViewRepresentable {
  let player: AVPlayer
  let onHoverChange: (Bool) -> Void
  let onTogglePlayback: () -> Void

  func makeNSView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.player = player
    view.onHoverChange = onHoverChange
    view.onTogglePlayback = onTogglePlayback
    return view
  }

  func updateNSView(_ view: PlayerLayerView, context: Context) {
    if view.player !== player {
      view.player = player
    }
    view.onHoverChange = onHoverChange
    view.onTogglePlayback = onTogglePlayback
  }

  static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
    view.player = nil
    view.onHoverChange = nil
    view.onTogglePlayback = nil
  }
}

private final class PlayerLayerView: NSView {
  private let playerLayer = AVPlayerLayer()
  private var hoverTrackingArea: NSTrackingArea?
  var onHoverChange: ((Bool) -> Void)?
  var onTogglePlayback: (() -> Void)?

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = playerLayer
    playerLayer.videoGravity = .resizeAspectFill
    playerLayer.backgroundColor = NSColor.black.cgColor
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    onHoverChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChange?(false)
  }

  override func mouseDown(with event: NSEvent) {
    onTogglePlayback?()
  }
}
