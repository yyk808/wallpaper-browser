import AppKit
import SwiftUI

struct WorkshopGridItem: View {
  let item: WorkshopItem
  let download: () -> Void

  @EnvironmentObject private var steamCMD: SteamCMDService
  @State private var isHovering = false

  private var record: DownloadRecord? { steamCMD.record(for: item.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        openWorkshop()
      } label: {
        AsyncImage(url: item.previewURL) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          case .failure:
            placeholder
          default:
            placeholder.overlay { ProgressView().controlSize(.small) }
          }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.title)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
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
      Button("打开创意工坊", systemImage: "safari") { openWorkshop() }
      Button("下载", systemImage: "arrow.down.circle", action: download)
        .disabled(record?.phase == .downloading || record?.phase == .extracting)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch record?.phase {
    case .queued, .downloading, .extracting:
      ProgressView()
        .controlSize(.small)
        .help(record?.phase.title ?? "正在下载")
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
      .help("在 Finder 中显示")
    case .failed, .cancelled:
      Button {
        steamCMD.retry(item.id)
      } label: {
        Image(systemName: "arrow.clockwise.circle")
      }
      .buttonStyle(.plain)
      .help("重试")
    case .none:
      Button(action: download) {
        Image(systemName: "arrow.down.circle")
      }
      .buttonStyle(.plain)
      .help("下载")
    }
  }

  private var placeholder: some View {
    Rectangle()
      .fill(Color(nsColor: .quaternaryLabelColor))
      .overlay {
        Image(systemName: "photo")
          .font(.title2)
          .foregroundStyle(.tertiary)
      }
  }

  private func openWorkshop() {
    if let url = item.workshopURL { NSWorkspace.shared.open(url) }
  }

  private func formatCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: String(value)
    }
  }
}
