import Foundation

struct ProcessResult: Sendable {
  let output: String
  let terminationStatus: Int32
}

enum ProcessRunnerError: LocalizedError {
  case alreadyRunning

  var errorDescription: String? {
    "已有一个 SteamCMD 任务正在运行。"
  }
}

nonisolated final class ProcessRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var currentProcess: Process?

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil
  ) async throws -> ProcessResult {
    try await Task.detached(priority: .userInitiated) { [self] in
      try runSynchronously(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    }.value
  }

  func cancel() {
    lock.lock()
    let process = currentProcess
    lock.unlock()
    if process?.isRunning == true {
      process?.terminate()
    }
  }

  private func runSynchronously(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) throws -> ProcessResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.standardOutput = pipe
    process.standardError = pipe

    lock.lock()
    guard currentProcess == nil else {
      lock.unlock()
      throw ProcessRunnerError.alreadyRunning
    }
    currentProcess = process
    lock.unlock()

    defer {
      lock.lock()
      currentProcess = nil
      lock.unlock()
    }

    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
      output: String(data: data, encoding: .utf8) ?? "",
      terminationStatus: process.terminationStatus
    )
  }
}
