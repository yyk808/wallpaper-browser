//
//  wallpaper_browserApp.swift
//  wallpaper-browser
//
//  Created by Neon on 2026/8/7.
//

import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case chinese = "zh-Hans"
  case english = "en"
  case japanese = "ja"
  case korean = "ko"
  case french = "fr"
  case german = "de"
  case spanish = "es"

  var id: String { rawValue }

  /// Native names remain recognizable while the app language is being changed.
  var displayName: String {
    switch self {
    case .chinese: "language.chinese.native"
    case .english: "English"
    case .japanese: "language.japanese.native"
    case .korean: "한국어"
    case .french: "Français"
    case .german: "Deutsch"
    case .spanish: "Español"
    }
  }
}

enum AppTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var localizedKey: LocalizedStringKey {
    switch self {
    case .system: "theme.system"
    case .light: "theme.light"
    case .dark: "theme.dark"
    }
  }
}

@MainActor
final class AppSettings: ObservableObject {
  @Published var language: AppLanguage {
    didSet {
      UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
    }
  }

  @Published var theme: AppTheme {
    didSet {
      UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
    }
  }

  private enum Keys {
    static let language = "app.language"
    static let theme = "app.theme"
  }

  init() {
    let savedLanguage = UserDefaults.standard.string(forKey: Keys.language)
      .flatMap(AppLanguage.init(rawValue:))
    let preferredLanguage = Locale.preferredLanguages.first.map { $0.lowercased() }
    if let savedLanguage {
      language = savedLanguage
    } else if preferredLanguage?.hasPrefix("zh") == true {
      language = .chinese
    } else if preferredLanguage?.hasPrefix("ja") == true {
      language = .japanese
    } else if preferredLanguage?.hasPrefix("ko") == true {
      language = .korean
    } else if preferredLanguage?.hasPrefix("fr") == true {
      language = .french
    } else if preferredLanguage?.hasPrefix("de") == true {
      language = .german
    } else if preferredLanguage?.hasPrefix("es") == true {
      language = .spanish
    } else {
      language = .english
    }
    theme = UserDefaults.standard.string(forKey: Keys.theme)
      .flatMap(AppTheme.init(rawValue:)) ?? .system
  }

  var locale: Locale { Locale(identifier: language.rawValue) }

  func localized(_ key: String) -> String {
    let components = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let formatKey = components[0]
    let format = localizedValue(formatKey)
    guard components.count > 1 else { return format }
    return String(
      format: format,
      locale: locale,
      arguments: components.dropFirst().map { $0 as NSString }
    )
  }

  private func localizedValue(_ key: String) -> String {
    if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    {
      let value = bundle.localizedString(forKey: key, value: key, table: nil)
      if value != key { return value }
    }
    if let path = Bundle.main.path(forResource: AppLanguage.english.rawValue, ofType: "lproj"),
      let englishBundle = Bundle(path: path)
    {
      let value = englishBundle.localizedString(forKey: key, value: key, table: nil)
      if value != key { return value }
    }
    return key
  }
}

@main
struct wallpaper_browserApp: App {
  @StateObject private var browseViewModel = BrowseViewModel()
  @StateObject private var steamCMD = SteamCMDService()
  @StateObject private var appSettings = AppSettings()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(browseViewModel)
        .environmentObject(steamCMD)
        .environmentObject(appSettings)
        .environment(\.locale, appSettings.locale)
        .preferredColorScheme(appSettings.theme.colorScheme)
    }
    .defaultSize(width: 1080, height: 700)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("command.refreshPreviews") {
          browseViewModel.refreshPreviews()
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    }

  }
}
