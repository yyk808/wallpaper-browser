import SwiftUI

struct ActiveFiltersBar: View {
  @ObservedObject var viewModel: BrowseViewModel
  @EnvironmentObject private var appSettings: AppSettings

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        if let type = viewModel.filters.wallpaperType {
          FilterToken(title: appSettings.localized("type.\(type)")) {
            var filters = viewModel.filters
            filters.wallpaperType = nil
            viewModel.applyFilters(filters)
          }
        }
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
        ForEach(viewModel.filters.excludedGenres.sorted(), id: \.self) { genre in
          FilterToken(title: genre, isExcluded: true) {
            viewModel.removeExcludedGenre(genre)
          }
        }
        Button("common.clearAll") { viewModel.clearFilters() }
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
    case "Everyone": appSettings.localized("rating.everyone")
    case "Questionable": appSettings.localized("rating.questionable")
    case "Mature": appSettings.localized("rating.mature")
    default: rating
    }
  }

  private func resolutionTitle(_ resolution: String) -> String {
    switch resolution {
    case "1920 x 1080": appSettings.localized("resolution.1080p")
    case "2560 x 1440": appSettings.localized("resolution.1440p")
    case "3840 x 2160": appSettings.localized("resolution.4k")
    case "3440 x 1440": appSettings.localized("resolution.ultrawide")
    case "1440 x 2560": appSettings.localized("resolution.vertical")
    default: resolution
    }
  }
}

private struct FilterToken: View {
  @EnvironmentObject private var appSettings: AppSettings
  let title: String
  var isExcluded = false
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      if isExcluded {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      Text(isExcluded ? "\(appSettings.localized("filter.excludedPrefix")) \(title)" : title)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
      .help("filter.remove")
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      isExcluded ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
      in: Capsule()
    )
  }
}
