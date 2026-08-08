import AppKit
import Combine
import QuickLookUI
import SwiftUI

struct DownloadsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @StateObject private var quickLook = QuickLookPreviewController()
  @State private var selection: Set<String> = []
  @State private var pendingDeletion: Set<String> = []
  @State private var isConfirmingDeletion = false
  @State private var deleteErrorMessage: String?

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
              onQuickLook: {
                selection = [record.id]
                showQuickLook([record.id])
              },
              onDelete: {
                requestDeletion([record.id])
              }
            )
            .tag(record.id)
          }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
          guard canQuickLook else { return .ignored }
          showQuickLook()
          return .handled
        }
      }
    }
    .navigationTitle("nav.downloads")
    .onChange(of: steamCMD.records.map(\.id)) { _, ids in
      selection.formIntersection(ids)
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
          showQuickLook()
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

  private var selectedRecords: [DownloadRecord] {
    steamCMD.records.filter { selection.contains($0.id) }
  }

  private var previewURLs: [URL] {
    previewURLs(for: selection)
  }

  private func previewURLs(for ids: Set<String>) -> [URL] {
    steamCMD.records.filter { ids.contains($0.id) }.compactMap { record in
      guard record.phase == .completed, let url = record.localURL,
        FileManager.default.fileExists(atPath: url.path)
      else { return nil }
      return url
    }
  }

  private var canQuickLook: Bool {
    !previewURLs.isEmpty
  }

  private var canDeleteSelection: Bool {
    !selectedRecords.isEmpty
      && selectedRecords.allSatisfy {
        ![.queued, .downloading, .extracting].contains($0.phase)
      }
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
    steamCMD.records.filter { pendingDeletion.contains($0.id) }.filter { record in
      guard let url = record.localURL else { return false }
      return FileManager.default.fileExists(atPath: url.path)
    }.count
  }

  private func showQuickLook(_ ids: Set<String>? = nil) {
    quickLook.toggle(urls: previewURLs(for: ids ?? selection))
  }

  private func requestDeletion(_ ids: Set<String>) {
    pendingDeletion = ids
    isConfirmingDeletion = !ids.isEmpty
  }

  private func performDeletion() {
    quickLook.close()
    let ids = pendingDeletion
    pendingDeletion = []
    deleteErrorMessage = steamCMD.moveRecordsToTrash(ids)
    selection.subtract(ids)
  }
}

private struct DownloadRow: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  let record: DownloadRecord
  let onQuickLook: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Color(nsColor: .controlBackgroundColor)
        WorkshopPreviewImage(url: record.item.previewURL)
      }
      .frame(width: 112, height: 63)
      .clipShape(RoundedRectangle(cornerRadius: 5))

      VStack(alignment: .leading, spacing: 5) {
        Text(record.item.title)
          .fontWeight(.medium)
          .lineLimit(1)
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

        if record.phase == .downloading {
          downloadProgress
        }
      }

      Spacer()
      actions
    }
    .padding(.vertical, 5)
    .contextMenu {
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
    guard record.phase == .completed, let url = record.localURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
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
    switch record.phase {
    case .queued, .downloading, .extracting:
      Button {
        steamCMD.cancel(record.id)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("common.cancel")
    case .completed:
      HStack(spacing: 6) {
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
      }
    case .failed, .cancelled:
      HStack(spacing: 6) {
        Button {
          steamCMD.retry(record.id)
        } label: {
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
private final class QuickLookPreviewController: NSObject, ObservableObject,
  QLPreviewPanelDataSource
{
  private var urls: [URL] = []

  func toggle(urls: [URL]) {
    guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.orderOut(nil)
      return
    }

    self.urls = urls
    panel.dataSource = self
    panel.currentPreviewItemIndex = 0
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    QLPreviewPanel.shared()?.orderOut(nil)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    urls.count
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    urls[index] as NSURL
  }
}
