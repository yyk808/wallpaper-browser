import SwiftUI

struct SteamLoginView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.dismiss) private var dismiss

  @State private var username = ""
  @State private var password = ""
  @State private var guardCode = ""
  @State private var showGuardCode = false

  var body: some View {
    VStack(spacing: 18) {
      Image(
        systemName: steamCMD.isLoggedIn ? "person.crop.circle.badge.checkmark" : "person.badge.key"
      )
      .font(.system(size: 38))
      .foregroundStyle(steamCMD.isLoggedIn ? .green : .secondary)

      Text(steamCMD.isLoggedIn ? "steam.signedIn" : "steam.signIn")
        .font(.title2)
        .fontWeight(.semibold)

      if !steamCMD.isLoggedIn {
        Text("steam.accountRequirement")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if steamCMD.isLoggedIn {
        Text(steamCMD.username)
          .foregroundStyle(.secondary)
        HStack {
          Button("steam.signOut") { steamCMD.logout() }
          Button("common.done") { dismiss() }
            .buttonStyle(.borderedProminent)
        }
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
          GridRow(alignment: .firstTextBaseline) {
            Text("steam.username")
              .foregroundStyle(.secondary)
            TextField("steam.username.placeholder", text: $username)
              .textFieldStyle(.roundedBorder)
              .frame(width: 260)
          }
          GridRow(alignment: .firstTextBaseline) {
            Text("steam.password")
              .foregroundStyle(.secondary)
            SecureField("steam.password.placeholder", text: $password)
              .textFieldStyle(.roundedBorder)
              .frame(width: 260)
          }
          if showGuardCode {
            GridRow(alignment: .firstTextBaseline) {
              Text("steam.guardCode")
                .foregroundStyle(.secondary)
              TextField("Steam Guard", text: $guardCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }
          }
        }

        if let error = steamCMD.loginError {
          Text(appSettings.localized(error))
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
          if error.contains("Guard") || error == "steam.error.guardRequired" {
            Button("steam.enterGuardCode") { showGuardCode = true }
              .buttonStyle(.link)
          }
        }

        HStack {
          if !username.isEmpty {
            Button("steam.useCachedSession") {
              Task { await steamCMD.loginWithCachedSession(username: username) }
            }
            .disabled(steamCMD.isLoggingIn)
          }
          Button("common.signIn") {
            Task {
              await steamCMD.login(
                username: username,
                password: password,
                guardCode: guardCode
              )
              password = ""
              if steamCMD.isLoggedIn { dismiss() }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(username.isEmpty || password.isEmpty || steamCMD.isLoggingIn)
          .keyboardShortcut(.defaultAction)
        }

        if steamCMD.isLoggingIn {
          ProgressView("steam.verifyingSession")
            .controlSize(.small)
        }
      }
    }
    .padding(28)
    .frame(width: 450)
    .frame(minHeight: 380)
    .onAppear {
      username = steamCMD.username
    }
  }
}
