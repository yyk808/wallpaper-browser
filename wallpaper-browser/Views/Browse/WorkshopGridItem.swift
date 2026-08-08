import AppKit
import SwiftUI

struct WorkshopGridItem: View {
  let item: WorkshopItem
  let previewRefreshToken: Int
  let showDetails: () -> Void
  let download: () -> Void

  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @State private var isHovering = false

  private var record: DownloadRecord? { steamCMD.record(for: item.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: showDetails) {
        ZStack {
          Color(nsColor: .controlBackgroundColor)

          WorkshopPreviewImage(
            url: item.previewURL,
            refreshToken: previewRefreshToken
          )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain)
      .help("detail.view")

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button(action: showDetails) {
          Text(item.title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(item.title)
        Spacer(minLength: 4)
        actionButton
      }

      HStack(spacing: 5) {
        if let genre = item.genreTags.first {
          Text(genre)
        }
        if item.subscriptions > 0 {
          if !item.genreTags.isEmpty { Text("·") }
          Label(formatCount(item.subscriptions), systemImage: "person.2")
        }
        Spacer(minLength: 0)
        if item.fileSize > 0 {
          Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .padding(8)
    .background(
      isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("detail.view", systemImage: "info.circle", action: showDetails)
      Button(
        steamCMD.hasDownloaded(item.id) ? "download.again" : "common.download",
        systemImage: "arrow.down.circle",
        action: download
      )
        .disabled(record?.phase == .downloading || record?.phase == .extracting)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch record?.phase {
    case .queued, .downloading, .extracting:
      ProgressView()
        .controlSize(.small)
        .help(
          record.map { appSettings.localized($0.phase.localizationKey) }
            ?? appSettings.localized("download.phase.downloading")
        )
    case .completed:
      Button {
        if let url = record?.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      .buttonStyle(.plain)
      .help("common.showInFinder")
    case .failed, .cancelled:
      Button {
        steamCMD.retry(item.id)
      } label: {
        Image(systemName: "arrow.clockwise.circle")
      }
      .buttonStyle(.plain)
      .help("common.retry")
    case .none:
      if steamCMD.hasDownloaded(item.id) {
        Button(action: download) {
          Image(systemName: "checkmark.circle")
            .foregroundStyle(.green)
        }
        .buttonStyle(.plain)
        .help("download.previouslyDownloaded")
      } else {
        Button(action: download) {
          Image(systemName: "arrow.down.circle")
        }
        .buttonStyle(.plain)
        .help("common.download")
      }
    }
  }

  private func formatCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: String(value)
    }
  }
}
