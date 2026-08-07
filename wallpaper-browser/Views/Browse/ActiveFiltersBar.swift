import SwiftUI

struct ActiveFiltersBar: View {
  @ObservedObject var viewModel: BrowseViewModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(visibleRatings, id: \.self) { rating in
          FilterToken(title: ratingTitle(rating)) {
            viewModel.removeRating(rating)
          }
        }
        if let resolution = viewModel.filters.resolution {
          FilterToken(title: resolutionTitle(resolution)) {
            viewModel.removeResolution()
          }
        }
        ForEach(viewModel.filters.genres.sorted(), id: \.self) { genre in
          FilterToken(title: genre) {
            viewModel.removeGenre(genre)
          }
        }
        Button("清除全部") { viewModel.clearFilters() }
          .buttonStyle(.link)
          .font(.caption)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
    }
  }

  private var visibleRatings: [String] {
    viewModel.filters.ratings == ["Everyone"] ? [] : viewModel.filters.ratings.sorted()
  }

  private func ratingTitle(_ rating: String) -> String {
    switch rating {
    case "Everyone": "所有人"
    case "Questionable": "辅导级"
    case "Mature": "成人"
    default: rating
    }
  }

  private func resolutionTitle(_ resolution: String) -> String {
    switch resolution {
    case "1920 x 1080": "1080p"
    case "2560 x 1440": "1440p"
    case "3840 x 2160": "4K"
    case "3440 x 1440": "超宽屏"
    case "1440 x 2560": "竖屏"
    default: resolution
    }
  }
}

private struct FilterToken: View {
  let title: String
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
      .help("移除此筛选")
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
  }
}
