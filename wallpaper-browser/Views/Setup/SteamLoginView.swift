import SwiftUI

struct SteamLoginView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
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

      Text(steamCMD.isLoggedIn ? "已登录 Steam" : "登录 Steam")
        .font(.title2)
        .fontWeight(.semibold)

      if !steamCMD.isLoggedIn {
        Text("下载创意工坊内容的账户需要拥有 Wallpaper Engine。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if steamCMD.isLoggedIn {
        Text(steamCMD.username)
          .foregroundStyle(.secondary)
        HStack {
          Button("退出登录") { steamCMD.logout() }
          Button("完成") { dismiss() }
            .buttonStyle(.borderedProminent)
        }
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
          GridRow(alignment: .firstTextBaseline) {
            Text("用户名")
              .foregroundStyle(.secondary)
            TextField("Steam 用户名", text: $username)
              .textFieldStyle(.roundedBorder)
              .frame(width: 260)
          }
          GridRow(alignment: .firstTextBaseline) {
            Text("密码")
              .foregroundStyle(.secondary)
            SecureField("Steam 密码", text: $password)
              .textFieldStyle(.roundedBorder)
              .frame(width: 260)
          }
          if showGuardCode {
            GridRow(alignment: .firstTextBaseline) {
              Text("验证码")
                .foregroundStyle(.secondary)
              TextField("Steam Guard", text: $guardCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }
          }
        }

        if let error = steamCMD.loginError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
          if error.contains("Guard") || error.contains("验证码") {
            Button("输入 Steam Guard 验证码") { showGuardCode = true }
              .buttonStyle(.link)
          }
        }

        HStack {
          if !username.isEmpty {
            Button("使用缓存会话") {
              Task { await steamCMD.loginWithCachedSession(username: username) }
            }
            .disabled(steamCMD.isLoggingIn)
          }
          Button("登录") {
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
          ProgressView("正在验证 Steam 会话…")
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
