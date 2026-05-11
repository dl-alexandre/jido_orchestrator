#!/usr/bin/env swift
import AVFoundation
import Foundation
import Speech

struct Config {
  var locale = "en-US"
  var queueCommand = ""
  var minChars = 8
  var partialInterval: TimeInterval = 4
}

func env(_ key: String, _ fallback: String = "") -> String {
  ProcessInfo.processInfo.environment[key] ?? fallback
}

func usage(exitCode: Int32 = 64) -> Never {
  fputs("""
  usage: scripts/meet_audio_stt_macos.swift [--locale en-US] [--queue-command path] [--min-chars n]

  Streams macOS default audio input through Apple's Speech recognizer and queues
  recognized transcript text for the Meet bridge.

  Common setup: set system/default input to BlackHole 2ch before running.

  """, stderr)
  exit(exitCode)
}

func parseConfig() -> Config {
  var config = Config()
  config.locale = env("JX_MEET_STT_LOCALE", "en-US")
  config.queueCommand = env("JX_MEET_STT_QUEUE_CMD")
  config.minChars = Int(env("JX_MEET_STT_MIN_CHARS", "8")) ?? 8
  config.partialInterval = TimeInterval(env("JX_MEET_STT_PARTIAL_INTERVAL", "4")) ?? 4

  var args = Array(CommandLine.arguments.dropFirst())
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--help", "-h":
      usage(exitCode: 0)
    case "--locale":
      guard let value = args.first, !value.isEmpty else { usage() }
      args.removeFirst()
      config.locale = value
    case "--queue-command":
      guard let value = args.first, !value.isEmpty else { usage() }
      args.removeFirst()
      config.queueCommand = value
    case "--min-chars":
      guard let value = args.first, let parsed = Int(value), parsed >= 1 else { usage() }
      args.removeFirst()
      config.minChars = parsed
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

func requirePermissions() {
  let micSemaphore = DispatchSemaphore(value: 0)
  var micGranted = false
  AVCaptureDevice.requestAccess(for: .audio) { allowed in
    micGranted = allowed
    micSemaphore.signal()
  }
  micSemaphore.wait()

  if !micGranted {
    fputs("microphone/audio input access was not granted\n", stderr)
    exit(77)
  }

  let speechSemaphore = DispatchSemaphore(value: 0)
  var speechStatus = SFSpeechRecognizerAuthorizationStatus.notDetermined
  SFSpeechRecognizer.requestAuthorization { status in
    speechStatus = status
    speechSemaphore.signal()
  }
  speechSemaphore.wait()

  if speechStatus != .authorized {
    fputs("speech recognition access was not granted: \(speechStatus.rawValue)\n", stderr)
    exit(77)
  }
}

func runProcess(_ executable: String, _ args: [String], stdin: Data) throws -> (Data, Data, Int32) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = args

  let input = Pipe()
  let stdout = Pipe()
  let stderrPipe = Pipe()
  process.standardInput = input
  process.standardOutput = stdout
  process.standardError = stderrPipe

  try process.run()
  input.fileHandleForWriting.write(stdin)
  try input.fileHandleForWriting.close()
  process.waitUntilExit()

  return (
    stdout.fileHandleForReading.readDataToEndOfFile(),
    stderrPipe.fileHandleForReading.readDataToEndOfFile(),
    process.terminationStatus
  )
}

func queueTranscript(_ transcript: String, command: String) {
  let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !text.isEmpty else { return }

  do {
    let (stdout, stderrData, status) = try runProcess(command, [], stdin: Data((text + "\n").utf8))
    if status != 0 {
      let message = String(data: stderrData, encoding: .utf8) ?? "queue command exited \(status)"
      fputs("queue failed: \(message)\n", stderr)
      return
    }

    if let output = String(data: stdout, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      print(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  } catch {
    fputs("queue failed: \(error.localizedDescription)\n", stderr)
  }
}

let config = parseConfig()
requirePermissions()

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: config.locale)), recognizer.isAvailable else {
  fputs("speech recognizer is unavailable for locale \(config.locale)\n", stderr)
  exit(69)
}

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)

if format.channelCount == 0 || format.sampleRate == 0 {
  fputs("default audio input is unavailable\n", stderr)
  exit(69)
}

let request = SFSpeechAudioBufferRecognitionRequest()
request.shouldReportPartialResults = true
if #available(macOS 13.0, *) {
  request.addsPunctuation = true
}

var lastQueued = ""
var lastPartialAt = Date.distantPast

let task = recognizer.recognitionTask(with: request) { result, error in
  if let result {
    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
    let now = Date()
    let changed = text != lastQueued
    let enoughText = text.count >= config.minChars
    let enoughTime = now.timeIntervalSince(lastPartialAt) >= config.partialInterval

    if changed && enoughText && (result.isFinal || enoughTime) {
      queueTranscript(text, command: config.queueCommand)
      lastQueued = text
      lastPartialAt = now
    }
  }

  if let error {
    fputs("speech recognition failed: \(error.localizedDescription)\n", stderr)
    CFRunLoopStop(CFRunLoopGetMain())
  }
}

input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
  request.append(buffer)
}

do {
  try engine.start()
  print("macOS speech STT listening on default input")
  CFRunLoopRun()
} catch {
  fputs("audio engine failed: \(error.localizedDescription)\n", stderr)
}

engine.stop()
input.removeTap(onBus: 0)
request.endAudio()
task.cancel()
