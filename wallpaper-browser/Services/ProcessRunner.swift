import Foundation

struct ProcessResult: Sendable {
  let output: String
  let terminationStatus: Int32
  let containsLoggedInOK: Bool
  let containsOK: Bool
  let containsError: Bool
  let containsFailed: Bool
  let errorLine: String?
  let containsSteamGuard: Bool
  let containsTwoFactor: Bool
  let containsInvalidPassword: Bool

  init(
    output: String,
    terminationStatus: Int32,
    containsLoggedInOK: Bool = false,
    containsOK: Bool = false,
    containsError: Bool = false,
    containsFailed: Bool = false,
    errorLine: String? = nil,
    containsSteamGuard: Bool = false,
    containsTwoFactor: Bool = false,
    containsInvalidPassword: Bool = false
  ) {
    self.output = output
    self.terminationStatus = terminationStatus
    self.containsLoggedInOK = containsLoggedInOK
    self.containsOK = containsOK
    self.containsError = containsError
    self.containsFailed = containsFailed
    self.errorLine = errorLine
    self.containsSteamGuard = containsSteamGuard
    self.containsTwoFactor = containsTwoFactor
    self.containsInvalidPassword = containsInvalidPassword
  }
}

enum ProcessRunnerError: LocalizedError {
  case alreadyRunning

  var errorDescription: String? {
    "steamcmd.error.alreadyRunning"
  }
}

nonisolated final class ProcessRunner: @unchecked Sendable {
  private static let outputReadSize = 8_192
  fileprivate static let outputTailLimit = 64 * 1_024
  private static let outputBatchLimit = 64 * 1_024
  private static let outputBatchInterval: TimeInterval = 0.075

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
    var output = ProcessOutputAccumulator()
    var pendingBatch = Data()
    var lastBatchDate = Date()
    while true {
      let data = handle.readData(ofLength: Self.outputReadSize)
      guard !data.isEmpty else { break }
      output.append(data)

      guard onOutput != nil else { continue }
      pendingBatch.append(data)
      let now = Date()
      if pendingBatch.count >= Self.outputBatchLimit
        || now.timeIntervalSince(lastBatchDate) >= Self.outputBatchInterval
      {
        emitPendingOutput(&pendingBatch, onOutput: onOutput)
        lastBatchDate = now
      }
    }
    emitPendingOutput(&pendingBatch, onOutput: onOutput)
    process.waitUntilExit()
    return ProcessResult(
      output: output.tail,
      terminationStatus: process.terminationStatus,
      containsLoggedInOK: output.containsLoggedInOK,
      containsOK: output.containsOK,
      containsError: output.containsError,
      containsFailed: output.containsFailed,
      errorLine: output.errorLine,
      containsSteamGuard: output.containsSteamGuard,
      containsTwoFactor: output.containsTwoFactor,
      containsInvalidPassword: output.containsInvalidPassword
    )
  }

  private func emitPendingOutput(
    _ pendingBatch: inout Data,
    onOutput: (@Sendable (String) -> Void)?
  ) {
    guard !pendingBatch.isEmpty else { return }
    let batch = pendingBatch
    pendingBatch.removeAll(keepingCapacity: true)
    onOutput?(String(decoding: batch, as: UTF8.self))
  }
}

private struct ProcessOutputAccumulator {
  private static let maxLineLength = 4 * 1_024
  private static let markerScanTailLength = 32

  private var tailBuffer = OutputTailBuffer(limit: ProcessRunner.outputTailLimit)
  private var pendingLine = ""
  private var errorLineIsPending = false
  private var markerScanTail = ""

  private(set) var containsLoggedInOK = false
  private(set) var containsOK = false
  private(set) var containsError = false
  private(set) var containsFailed = false
  private(set) var errorLine: String?
  private(set) var containsSteamGuard = false
  private(set) var containsTwoFactor = false
  private(set) var containsInvalidPassword = false

  var tail: String { tailBuffer.string }

  mutating func append(_ data: Data) {
    tailBuffer.append(data)
    let text = String(decoding: data, as: UTF8.self)
    updateMarkers(with: text)
    updateErrorLine(with: text)
  }

  private mutating func updateMarkers(with text: String) {
    let searchable = markerScanTail + text
    containsLoggedInOK = containsLoggedInOK || searchable.contains("Logged in OK")
    containsOK = containsOK || searchable.contains("OK")
    containsError =
      containsError || searchable.range(of: "ERROR", options: [.caseInsensitive]) != nil
    containsFailed =
      containsFailed || searchable.range(of: "FAILED", options: [.caseInsensitive]) != nil
    containsSteamGuard =
      containsSteamGuard
      || searchable.range(of: "Steam Guard", options: [.caseInsensitive]) != nil
    containsTwoFactor =
      containsTwoFactor
      || searchable.range(of: "Two-factor", options: [.caseInsensitive]) != nil
    containsInvalidPassword =
      containsInvalidPassword
      || searchable.range(of: "Invalid Password", options: [.caseInsensitive]) != nil
    markerScanTail = String(searchable.suffix(Self.markerScanTailLength))
  }

  private mutating func updateErrorLine(with text: String) {
    let combined = pendingLine + text
    let lines = combined.components(separatedBy: .newlines)
    guard lines.count > 1 else {
      if isErrorLine(combined), errorLine == nil || errorLineIsPending {
        errorLine = boundedErrorLine(combined)
        errorLineIsPending = true
      }
      pendingLine = boundedLine(combined)
      return
    }

    for line in lines.dropLast() where isErrorLine(line) {
      if errorLine == nil || errorLineIsPending {
        errorLine = boundedErrorLine(line)
        errorLineIsPending = false
      }
    }
    pendingLine = boundedLine(lines.last ?? "")
  }

  private mutating func boundedLine(_ line: String) -> String {
    guard line.count > Self.maxLineLength else { return line }
    return String(line.suffix(Self.maxLineLength))
  }

  private func isErrorLine(_ line: String) -> Bool {
    line.range(of: "ERROR", options: [.caseInsensitive]) != nil
      || line.range(of: "FAILED", options: [.caseInsensitive]) != nil
  }

  private func boundedErrorLine(_ line: String) -> String {
    guard line.count > Self.maxLineLength else { return line }
    if let marker = line.range(of: "ERROR", options: [.caseInsensitive])
      ?? line.range(of: "FAILED", options: [.caseInsensitive])
    {
      let markerOffset = line.distance(from: line.startIndex, to: marker.lowerBound)
      let startOffset = max(0, markerOffset - Self.maxLineLength / 2)
      let start = line.index(line.startIndex, offsetBy: startOffset)
      return String(line[start...].prefix(Self.maxLineLength))
    }
    return String(line.prefix(Self.maxLineLength))
  }
}

private struct OutputTailBuffer {
  private let limit: Int
  private var chunks: [Data] = []
  private var firstChunkIndex = 0
  private var byteCount = 0

  init(limit: Int) {
    self.limit = limit
  }

  var string: String {
    var data = Data()
    data.reserveCapacity(byteCount)
    for chunk in chunks[firstChunkIndex...] {
      data.append(chunk)
    }
    return String(decoding: data, as: UTF8.self)
  }

  mutating func append(_ data: Data) {
    guard !data.isEmpty else { return }
    if data.count >= limit {
      chunks = [Data(data.suffix(limit))]
      firstChunkIndex = 0
      byteCount = limit
      return
    }

    chunks.append(data)
    byteCount += data.count
    while byteCount > limit, firstChunkIndex < chunks.count {
      let excess = byteCount - limit
      let first = chunks[firstChunkIndex]
      if first.count <= excess {
        byteCount -= first.count
        firstChunkIndex += 1
      } else {
        chunks[firstChunkIndex] = Data(first.suffix(first.count - excess))
        byteCount -= excess
      }
    }

    if firstChunkIndex > 32 && firstChunkIndex * 2 > chunks.count {
      chunks.removeFirst(firstChunkIndex)
      firstChunkIndex = 0
    }
  }
}
