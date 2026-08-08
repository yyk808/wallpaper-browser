import Foundation

struct ProcessResult: Sendable {
  let output: String
  let terminationStatus: Int32
}

enum ProcessRunnerError: LocalizedError {
  case alreadyRunning

  var errorDescription: String? {
    "steamcmd.error.alreadyRunning"
  }
}

nonisolated final class ProcessRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var currentProcess: Process?

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    standardInput: String? = nil,
    onOutput: (@Sendable (String) -> Void)? = nil
  ) async throws -> ProcessResult {
    try await Task.detached(priority: .userInitiated) { [self] in
      try runSynchronously(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL,
        standardInput: standardInput,
        onOutput: onOutput
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
    currentDirectoryURL: URL?,
    standardInput: String?,
    onOutput: (@Sendable (String) -> Void)?
  ) throws -> ProcessResult {
    let process = Process()
    let pipe = Pipe()
    let inputPipe = standardInput.map { _ in Pipe() }
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.standardInput = inputPipe
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
    if let standardInput, let inputHandle = inputPipe?.fileHandleForWriting {
      inputHandle.write(Data(standardInput.utf8))
      try? inputHandle.close()
    }
    let handle = pipe.fileHandleForReading
    var outputData = Data()
    while true {
      let data = handle.readData(ofLength: 8_192)
      guard !data.isEmpty else { break }
      outputData.append(data)
      onOutput?(String(decoding: data, as: UTF8.self))
    }
    process.waitUntilExit()
    return ProcessResult(
      output: String(decoding: outputData, as: UTF8.self),
      terminationStatus: process.terminationStatus
    )
  }
}
