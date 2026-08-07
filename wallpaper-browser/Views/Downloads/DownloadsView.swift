import AppKit
import SwiftUI

struct DownloadsView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService

  var body: some View {
    Group {
      if steamCMD.records.isEmpty {
        ContentUnavailableView(
          "还没有下载内容",
          systemImage: "arrow.down.circle",
          description: Text("从创意工坊选择视频壁纸开始下载。")
        )
      } else {
        List {
          ForEach(steamCMD.records) { record in
            DownloadRow(record: record)
          }
        }
        .listStyle(.inset)
      }
    }
    .navigationTitle("下载内容")
    .toolbar {
      ToolbarItem {
        Button {
          NSWorkspace.shared.open(steamCMD.libraryDirectory)
        } label: {
          Image(systemName: "folder")
        }
        .help("打开壁纸目录")
      }
      ToolbarItem {
        Button {
          steamCMD.clearFinishedRecords()
        } label: {
          Image(systemName: "trash")
        }
        .help("清除已结束的记录")
        .disabled(
          !steamCMD.records.contains { [.completed, .failed, .cancelled].contains($0.phase) })
      }
    }
  }
}

private struct DownloadRow: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  let record: DownloadRecord

  var body: some View {
    HStack(spacing: 14) {
      AsyncImage(url: record.item.previewURL) { phase in
        if case .success(let image) = phase {
          image.resizable().scaledToFill()
        } else {
          Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
      }
      .frame(width: 112, height: 63)
      .clipShape(RoundedRectangle(cornerRadius: 5))

      VStack(alignment: .leading, spacing: 5) {
        Text(record.item.title)
          .fontWeight(.medium)
          .lineLimit(1)
        HStack(spacing: 6) {
          phaseIcon
          Text(record.phase.title)
          if !record.detail.isEmpty {
            Text("·")
            Text(record.detail).lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(record.phase == .failed ? Color.red : Color.secondary)
      }

      Spacer()
      actions
    }
    .padding(.vertical, 5)
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
      .help("取消")
    case .completed:
      Button {
        if let url = record.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.borderless)
      .help("在 Finder 中显示")
    case .failed, .cancelled:
      HStack(spacing: 6) {
        Button {
          steamCMD.retry(record.id)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("重试")
        Button {
          steamCMD.removeRecord(record.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("移除记录")
      }
    }
  }
}
