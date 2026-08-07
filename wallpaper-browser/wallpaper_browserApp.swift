//
//  wallpaper_browserApp.swift
//  wallpaper-browser
//
//  Created by Neon on 2026/8/7.
//

import SwiftUI

@main
struct wallpaper_browserApp: App {
  @StateObject private var browseViewModel = BrowseViewModel()
  @StateObject private var steamCMD = SteamCMDService()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(browseViewModel)
        .environmentObject(steamCMD)
    }
    .defaultSize(width: 1080, height: 700)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("刷新创意工坊") {
          browseViewModel.refresh()
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(steamCMD)
    }
    .defaultSize(width: 720, height: 480)
  }
}
