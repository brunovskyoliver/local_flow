import CryptoKit
import Foundation

// flowd-speech: the speech worker flowd starts as a child process (Feature 014 R10,
// contracts/speech-worker-ipc.md). It runs the app's own FluidAudio recognition and
// term-boosting code behind one ModelLifecycleCoordinator, talks only to flowd over
// stdin/stdout, and logs job IDs, sample counts, durations, states and codes to stderr.
//
//   flowd-speech serve --models <dir> [--descriptors <dir>]
//   flowd-speech provision --models <dir> [--booster] [--descriptors <dir>]
//
// Descriptors default to the pinned parakeet-v3.json and parakeet-ctc-110m.json next to
// the executable, which scripts/install-remote-server.sh installs there.

let workerBuild = "flowd-speech 1"

/// The worker's own log: a duplicate of the original stderr. File descriptor 2 then
/// points at /dev/null, because FluidAudio mirrors its log lines, which contain
/// transcript text and Dictionary terms, to the console, and flowd copies this
/// process's stderr into its log (FR-027).
let workerLog: FileHandle = {
  let original = dup(STDERR_FILENO)
  let null = open("/dev/null", O_WRONLY)
  if null >= 0 {
    dup2(null, STDERR_FILENO)
    close(null)
  }
  return FileHandle(fileDescriptor: original >= 0 ? original : STDERR_FILENO, closeOnDealloc: false)
}()

func log(_ message: String) {
  workerLog.write(Data((message + "\n").utf8))
}

func option(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

struct Descriptors {
  let speech: ModelDescriptor
  let speechHash: String
  let booster: ModelDescriptor?

  init(directory: URL) throws {
    let speechData = try Data(contentsOf: directory.appendingPathComponent("parakeet-v3.json"))
    speech = try JSONDecoder().decode(ModelDescriptor.self, from: speechData)
    speechHash = SHA256.hash(data: speechData).map { String(format: "%02x", $0) }.joined()
    booster = (try? Data(contentsOf: directory.appendingPathComponent("parakeet-ctc-110m.json")))
      .flatMap { try? JSONDecoder().decode(ModelDescriptor.self, from: $0) }
  }
}

/// Serializes frames to stdout; lifecycle observations and job answers share it.
final class FrameWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var readySent = false

  /// `ready` (or `unavailable`) is always the first frame; lifecycle states observed
  /// while the model loads for it are not sent.
  func sendState(_ state: String) {
    guard lock.withLock({ readySent }) else { return }
    send(["type": "state", "state": state])
  }

  func send(_ header: [String: Any]) {
    if ["ready", "unavailable"].contains(header["type"] as? String) {
      lock.withLock { readySent = true }
    }
    guard let frame = try? WorkerFraming.encode(header) else {
      log("frame_encode_failed type=\(header["type"] as? String ?? "?")")
      exit(1)
    }
    lock.withLock { FileHandle.standardOutput.write(frame) }
  }
}

/// Reads frames on a dedicated thread so a blocking read never holds the main actor.
final class FrameReader: @unchecked Sendable {
  struct Box: @unchecked Sendable { let frame: WorkerFraming.Frame? }
  let frames: AsyncThrowingStream<Box, any Error>

  init() {
    var continuation: AsyncThrowingStream<Box, any Error>.Continuation!
    frames = AsyncThrowingStream { continuation = $0 }
    let output = continuation!
    let thread = Thread {
      let input = FileHandle.standardInput
      do {
        while true {
          let frame = try WorkerFraming.read { count in
            var data = Data()
            while data.count < count {
              guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty
              else { break }
              data.append(chunk)
            }
            return data
          }
          output.yield(Box(frame: frame))
          if frame == nil { break }
        }
        output.finish()
      } catch {
        output.finish(throwing: error)
      }
    }
    thread.start()
  }
}

func window(_ window: TranscriptionWindow, sampleCount: Int) -> [String: Any] {
  func timing(_ timing: RecognitionEvidence.Timing) -> [String: Any] {
    var object: [String: Any] = [:]
    if let value = timing.value { object["value"] = value } else { object["value"] = NSNull() }
    if let invalid = timing.invalid { object["invalid"] = invalid }
    return object
  }
  var object: [String: Any] = [
    "sample_count": sampleCount, "text": window.text,
    "tokens": window.tokens.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
    "boost_hints": window.boostHints.map {
      ["source": $0.source, "canonical": $0.canonical, "entry_id": $0.entryID]
    },
  ]
  if let evidence = window.evidence {
    object["evidence"] = [
      "text": evidence.text, "samples": evidence.samples,
      "padded_samples": evidence.paddedSamples, "timings_available": evidence.timingsAvailable,
      "tokens": evidence.tokens.map {
        ["text": $0.text, "start": timing($0.start), "end": timing($0.end)]
      },
    ]
  }
  return object
}

func boost(_ header: [String: Any]) -> VocabularyBoostTerms? {
  guard let boost = header["boost"] as? [String: Any],
    let terms = boost["terms"] as? [[String: Any]], !terms.isEmpty
  else { return nil }
  let parsed = terms.compactMap { term -> VocabularyBoostTerms.Term? in
    guard let id = term["entry_id"] as? String, let canonical = term["canonical"] as? String
    else { return nil }
    return .init(entryID: id, canonical: canonical)
  }
  let governed = Set(boost["governed"] as? [String] ?? [])
  // The rescorer is rebuilt when the key changes; the key is the terms themselves.
  let key = SHA256.hash(
    data: Data(parsed.map { $0.entryID + "\u{1F}" + $0.canonical }.joined(separator: "\u{1E}").utf8)
  ).map { String(format: "%02x", $0) }.joined()
  return parsed.isEmpty ? nil : VocabularyBoostTerms(terms: parsed, key: key, governed: governed)
}

func serve(models: URL, descriptors: Descriptors) async -> Int32 {
  let writer = FrameWriter()
  let speech = ModelProvisioner(
    descriptor: descriptors.speech, rootURL: models.appendingPathComponent("parakeet-v3"))
  let local: LocalModelDescriptor
  do { local = try await speech.verifiedLocalDescriptor() } catch {
    // The case name only; provisioner errors carry no paths or content.
    log("state=unavailable reason=model_missing")
    writer.send(["type": "unavailable", "reason": "model_missing"])
    return 0
  }
  var boostModel: LocalModelDescriptor?
  if let booster = descriptors.booster {
    boostModel = try? await ModelProvisioner(
      descriptor: booster, rootURL: models.appendingPathComponent("parakeet-ctc-110m")
    ).verifiedLocalDescriptor()
  }
  let lifecycle = ModelLifecycleCoordinator(
    observe: { state, _, duration in
      guard duration == 0 else { return }
      switch state {
      case .active: writer.sendState("active")
      case .releasing: writer.sendState("releasing")
      default: break
      }
    },
    factory: { [boostModel] in
      try await FluidAudioEngineFactory(descriptor: local, boostModel: boostModel).makeRuntime()
    })
  // The model loads once, before `ready`, and stays resident while the process runs
  // (FR-032): no idle release on the server.
  await lifecycle.setKeepLoaded(true)
  let loadStarted = ContinuousClock.now
  do { try await lifecycle.loadIfIdle() } catch {
    log("state=load_failed")
    return 1
  }
  log("state=ready load_ms=\((ContinuousClock.now - loadStarted).milliseconds)")
  var model: [String: Any] = [
    "engine": "FluidAudio", "model_id": descriptors.speech.modelID,
    "model_revision": descriptors.speech.sourceRevision, "manifest_hash": descriptors.speechHash,
    "sdk": descriptors.speech.sdkCompatibility, "worker_build": workerBuild,
  ]
  if boostModel != nil { model["booster"] = VocabularyBoostPolicy.version }
  writer.send(["type": "ready", "protocol": 1, "model": model])

  do {
    for try await box in FrameReader().frames {
      guard let frame = box.frame else { break }
      switch frame.type {
      case "recognize":
        guard let job = frame.integer("job") else {
          log("frame_malformed")
          return 1
        }
        let samples = WorkerFraming.samples(frame.payload)
        let started = ContinuousClock.now
        guard samples.allSatisfy(\.isFinite) else {
          writer.send(["type": "error", "job": job, "code": "invalid_audio"])
          log("job=\(job) samples=\(samples.count) code=invalid_audio")
          continue
        }
        // One lease per job: this job's terms are bound to it and end with it (FR-014).
        do {
          let lease = try await lifecycle.acquire(session: UUID(), boost: boost(frame.header))
          do {
            let recognized = try await lifecycle.transcribe(lease, samples: samples)
            try await lifecycle.finish(lease)
            let elapsed = (ContinuousClock.now - started).milliseconds
            writer.send([
              "type": "result", "job": job, "recognition_ms": elapsed,
              "window": window(recognized, sampleCount: samples.count),
            ])
            log("job=\(job) samples=\(samples.count) ms=\(elapsed)")
          } catch {
            await lifecycle.cancelAndJoin(lease)
            throw error
          }
        } catch {
          let code =
            (error as? DictationFailure) == .modelUnavailable
            ? "model_unavailable"
            : (error as? DictationFailure) == .invalidAudio ? "invalid_audio" : "failed"
          writer.send(["type": "error", "job": job, "code": code])
          log("job=\(job) samples=\(samples.count) code=\(code)")
        }
      case "shutdown":
        log("state=shutdown")
        try? await lifecycle.shutdownIfIdle()
        return 0
      default:
        log("frame_unknown_type")
        return 1
      }
    }
  } catch {
    log("frame_malformed")
    return 1
  }
  // flowd closed stdin: release the runtime and exit.
  try? await lifecycle.shutdownIfIdle()
  return 0
}

func provision(models: URL, descriptors: Descriptors, booster: Bool) async -> Int32 {
  var targets = [("parakeet-v3", descriptors.speech)]
  if booster {
    guard let descriptor = descriptors.booster else {
      log("provision booster_descriptor_missing")
      return 1
    }
    targets.append(("parakeet-ctc-110m", descriptor))
  }
  for (name, descriptor) in targets {
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: models.appendingPathComponent(name))
    do {
      if (try? await provisioner.verifiedLocalDescriptor(fullHash: true)) == nil {
        log("provision model=\(name) state=downloading")
        _ = try await provisioner.download()
      }
      _ = try await provisioner.verifiedLocalDescriptor(fullHash: true)
      log("provision model=\(name) state=verified")
    } catch {
      log("provision model=\(name) state=failed")
      return 1
    }
  }
  return 0
}

extension Duration {
  var milliseconds: Int64 {
    components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
  }
}

_ = workerLog
let arguments = CommandLine.arguments
let usage = "usage: flowd-speech serve|provision --models <dir> [--booster] [--descriptors <dir>]"
guard arguments.count >= 2, ["serve", "provision"].contains(arguments[1]),
  let modelsPath = option("--models", in: arguments)
else {
  log(usage)
  exit(64)
}
let executableDirectory = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath()
  .deletingLastPathComponent()
let descriptorDirectory =
  option("--descriptors", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
  ?? executableDirectory
let descriptors: Descriptors
do { descriptors = try Descriptors(directory: descriptorDirectory) } catch {
  log("descriptor_missing")
  exit(1)
}
let models = URL(fileURLWithPath: modelsPath, isDirectory: true)
let status =
  arguments[1] == "serve"
  ? await serve(models: models, descriptors: descriptors)
  : await provision(
    models: models, descriptors: descriptors, booster: arguments.contains("--booster"))
exit(status)
