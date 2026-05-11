#!/usr/bin/env swift
import AVFoundation
import Foundation

struct Config {
  var segmentSeconds: TimeInterval = 5
  var silenceThreshold: Float = 0.006
  var model = "gpt-4o-mini-transcribe"
  var queueCommand = ""
  var once = false
}

func env(_ key: String, _ fallback: String = "") -> String {
  ProcessInfo.processInfo.environment[key] ?? fallback
}

func parseBool(_ value: String) -> Bool {
  ["1", "true", "yes", "on"].contains(value.lowercased())
}

func usage(exitCode: Int32 = 64) -> Never {
  fputs("""
  usage: scripts/meet_audio_stt_openai.swift [--once] [--segment-seconds n] [--silence-threshold n] [--model name] [--queue-command path]

  Records short chunks from the macOS default audio input, sends them to OpenAI
  audio transcriptions, and queues non-empty transcript text for the Meet bridge.

  Required: OPENAI_API_KEY
  Common setup: set system/default input to BlackHole 2ch before running.

  """, stderr)
  exit(exitCode)
}

func parseConfig() -> Config {
  var config = Config()
  config.segmentSeconds = TimeInterval(env("JX_MEET_STT_SEGMENT_SECONDS", "5")) ?? 5
  config.silenceThreshold = Float(env("JX_MEET_STT_SILENCE_THRESHOLD", "0.006")) ?? 0.006
  config.model = env("JX_MEET_STT_MODEL", "gpt-4o-mini-transcribe")
  config.queueCommand = env("JX_MEET_STT_QUEUE_CMD")
  config.once = parseBool(env("JX_MEET_STT_ONCE"))

  var args = Array(CommandLine.arguments.dropFirst())
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--help", "-h":
      usage(exitCode: 0)
    case "--once":
      config.once = true
    case "--segment-seconds":
      guard let value = args.first, let seconds = TimeInterval(value), seconds > 0 else { usage() }
      args.removeFirst()
      config.segmentSeconds = seconds
    case "--silence-threshold":
      guard let value = args.first, let threshold = Float(value), threshold >= 0 else { usage() }
      args.removeFirst()
      config.silenceThreshold = threshold
    case "--model":
      guard let value = args.first, !value.isEmpty else { usage() }
      args.removeFirst()
      config.model = value
    case "--queue-command":
      guard let value = args.first, !value.isEmpty else { usage() }
      args.removeFirst()
      config.queueCommand = value
    default:
      fputs("unknown argument: \(arg)\n", stderr)
      usage()
    }
  }

  if config.queueCommand.isEmpty {
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    config.queueCommand = root.appendingPathComponent("scripts/meet_chat_input_queue.sh").path
  }

  return config
}

func requireMicrophoneAccess() {
  let semaphore = DispatchSemaphore(value: 0)
  var granted = false

  AVCaptureDevice.requestAccess(for: .audio) { allowed in
    granted = allowed
    semaphore.signal()
  }

  semaphore.wait()

  if !granted {
    fputs("microphone/audio input access was not granted\n", stderr)
    exit(77)
  }
}

func runProcess(_ executable: String, _ args: [String], stdin: Data? = nil) throws -> (Data, Data, Int32) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = args

  let stdout = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdout
  process.standardError = stderrPipe

  if let stdin {
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(stdin)
    try input.fileHandleForWriting.close()
  } else {
    try process.run()
  }

  process.waitUntilExit()
  return (
    stdout.fileHandleForReading.readDataToEndOfFile(),
    stderrPipe.fileHandleForReading.readDataToEndOfFile(),
    process.terminationStatus
  )
}

func recordSegment(seconds: TimeInterval, threshold: Float) throws -> (URL, Float) {
  let engine = AVAudioEngine()
  let input = engine.inputNode
  let format = input.outputFormat(forBus: 0)

  if format.channelCount == 0 || format.sampleRate == 0 {
    throw NSError(domain: "meet_audio_stt", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "default audio input is unavailable"
    ])
  }

  let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("jx-meet-stt-\(UUID().uuidString).wav")
  let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)

  let lock = NSLock()
  var peakRMS: Float = 0

  input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
    if let channels = buffer.floatChannelData {
      let frames = Int(buffer.frameLength)
      let channelCount = Int(buffer.format.channelCount)
      var sum: Float = 0
      var count = 0

      for channel in 0..<channelCount {
        let samples = channels[channel]
        for frame in 0..<frames {
          let sample = samples[frame]
          sum += sample * sample
          count += 1
        }
      }

      if count > 0 {
        let rms = sqrt(sum / Float(count))
        lock.lock()
        peakRMS = max(peakRMS, rms)
        lock.unlock()
      }
    }

    do {
      try audioFile.write(from: buffer)
    } catch {
      fputs("audio write failed: \(error.localizedDescription)\n", stderr)
    }
  }

  try engine.start()
  Thread.sleep(forTimeInterval: seconds)
  engine.stop()
  input.removeTap(onBus: 0)

  lock.lock()
  let rms = peakRMS
  lock.unlock()

  if rms < threshold {
    try? FileManager.default.removeItem(at: fileURL)
  }

  return (fileURL, rms)
}

func transcribe(fileURL: URL, model: String, apiKey: String) throws -> String {
  let args = [
    "-sS",
    "--fail",
    "https://api.openai.com/v1/audio/transcriptions",
    "-H", "Authorization: Bearer \(apiKey)",
    "-F", "file=@\(fileURL.path)",
    "-F", "model=\(model)",
    "-F", "response_format=text"
  ]

  let (stdout, stderrData, status) = try runProcess("/usr/bin/curl", args)
  if status != 0 {
    let message = String(data: stderrData, encoding: .utf8) ?? "curl exited \(status)"
    throw NSError(domain: "meet_audio_stt", code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)
    ])
  }

  return (String(data: stdout, encoding: .utf8) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func queueTranscript(_ transcript: String, command: String) throws {
  guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return
  }

  let data = Data((transcript + "\n").utf8)
  let (stdout, stderrData, status) = try runProcess(command, [], stdin: data)
  if status != 0 {
    let message = String(data: stderrData, encoding: .utf8) ?? "queue command exited \(status)"
    throw NSError(domain: "meet_audio_stt", code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)
    ])
  }

  if let output = String(data: stdout, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    print(output.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

let config = parseConfig()
let apiKey = env("OPENAI_API_KEY")
if apiKey.isEmpty {
  fputs("OPENAI_API_KEY is required\n", stderr)
  exit(78)
}

requireMicrophoneAccess()

repeat {
  do {
    let (fileURL, rms) = try recordSegment(seconds: config.segmentSeconds, threshold: config.silenceThreshold)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    if rms < config.silenceThreshold {
      print("skipped silent segment rms=\(String(format: "%.5f", rms))")
    } else {
      let transcript = try transcribe(fileURL: fileURL, model: config.model, apiKey: apiKey)
      if transcript.isEmpty {
        print("skipped empty transcript")
      } else {
        try queueTranscript(transcript, command: config.queueCommand)
      }
    }
  } catch {
    fputs("meet audio stt failed: \(error.localizedDescription)\n", stderr)
  }
} while !config.once
