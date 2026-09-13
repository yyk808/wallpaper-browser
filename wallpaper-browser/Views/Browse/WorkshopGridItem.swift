import AppKit
import SwiftUI

struct WorkshopGridItem: View, Equatable {
  let item: WorkshopItem
  let previewRefreshToken: Int
  let transitionSourceID: String
  let transitionNamespace: Namespace.ID
  let isTransitionSource: Bool
  let record: DownloadRecord?
  let hasDownloaded: Bool
  let showDetails: () -> Void
  let download: () -> Void
  let retry: () -> Void
  var isSelected: Bool? = nil
  var toggleSelection: (() -> Void)? = nil

  @EnvironmentObject private var appSettings: AppSettings

  static func == (lhs: WorkshopGridItem, rhs: WorkshopGridItem) -> Bool {
    lhs.item == rhs.item && lhs.previewRefreshToken == rhs.previewRefreshToken
      && lhs.transitionSourceID == rhs.transitionSourceID
      && lhs.isTransitionSource == rhs.isTransitionSource
      && lhs.record == rhs.record && lhs.hasDownloaded == rhs.hasDownloaded
      && lhs.isSelected == rhs.isSelected
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .bottomTrailing) {
        Button(action: showDetails) {
          ZStack {
            Color(nsColor: .controlBackgroundColor)

            WorkshopPreviewImage(
              url: item.previewURL,
              refreshToken: previewRefreshToken,
              allowsAnimation: false
            )
          }
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .workshopDetailTransitionSource(
            id: transitionSourceID,
            in: transitionNamespace,
            isActive: isTransitionSource
          )
        }
        .buttonStyle(.plain)
        .help("detail.view")

        Group {
          if item.isVideo {
            actionButton
          } else {
            Button(action: showDetails) {
              Image(systemName: "info.circle")
                .foregroundStyle(.white).padding(7)
                .background(Color.black.opacity(0.58), in: Circle())
            }.buttonStyle(.plain).help("explore.unsupported")
          }
        }.padding(9)
      }
      .overlay(alignment: .topLeading) {
        if let isSelected, let toggleSelection {
          Toggle("explore.select", isOn: Binding(
            get: { isSelected },
            set: { _ in toggleSelection() }
          ))
          .toggleStyle(WorkshopCoverSelectionStyle())
          .padding(9)
        }
      }

      Button(action: showDetails) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 4)

          if let genre = item.genreTags.first {
            Text(genre)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
      }
      .buttonStyle(.plain)
      .help(item.title)

      HStack(spacing: 7) {
        if item.subscriptions > 0 {
          Label(formatCount(item.subscriptions), systemImage: "person.2")
        }
        if item.positiveVotes > 0 || item.negativeVotes > 0 || item.numComments > 0 {
          Label(formatCount(item.positiveVotes), systemImage: "hand.thumbsup")
          Label(formatCount(item.negativeVotes), systemImage: "hand.thumbsdown")
          Label(formatCount(item.numComments), systemImage: "bubble.left")
        }
        Spacer(minLength: 4)
        if item.fileSize > 0 {
          Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.78)
      .allowsTightening(true)
    }
    .padding(9)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .contextMenu {
      Button("detail.view", systemImage: "info.circle", action: showDetails)
      Button(
        hasDownloaded ? "download.again" : "common.download",
        systemImage: "arrow.down.circle",
        action: download
      )
        .disabled(!item.isVideo || record?.phase == .downloading || record?.phase == .extracting)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch record?.phase {
    case .queued, .downloading, .extracting:
      ProgressView()
        .controlSize(.small)
        .tint(.white)
        .padding(7)
        .background(Color.black.opacity(0.58), in: Circle())
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
          .padding(7)
          .background(Color.black.opacity(0.58), in: Circle())
      }
      .buttonStyle(.plain)
      .help("common.showInFinder")
    case .failed, .cancelled:
      Button(action: retry) {
        Image(systemName: "arrow.clockwise.circle")
          .foregroundStyle(.white)
          .padding(7)
          .background(Color.black.opacity(0.58), in: Circle())
      }
      .buttonStyle(.plain)
      .help("common.retry")
    case .none:
      if hasDownloaded {
        Button(action: download) {
          Image(systemName: "checkmark.circle")
            .foregroundStyle(.green)
            .padding(7)
            .background(Color.black.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .help("download.previouslyDownloaded")
      } else {
        Button(action: download) {
          Image(systemName: "arrow.down")
            .foregroundStyle(.white)
            .padding(7)
            .background(Color.black.opacity(0.58), in: Circle())
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


private struct WorkshopCoverSelectionStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
        .foregroundStyle(configuration.isOn ? Color.green : Color.white)
        .padding(7)
        .background(Color.black.opacity(0.58), in: Circle())
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("explore.select")
    .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
  }
}
