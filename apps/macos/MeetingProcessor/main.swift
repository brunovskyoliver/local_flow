import CryptoKit
import FluidAudio
import Foundation
import LocalFlowCore
import LocalFlowSpeech

// flowd-meeting: one handed-off meeting, processed headless on the server Mac.
//
//   flowd-meeting --bundle <dir> --meeting <UUID> --models <dir> --helper <path>
//
// <dir>/bundle.sqlite is the meeting's slice of the client's history database and
// <dir> its meeting storage root (<UUID>/mic-0001.aac ...). The app's own finalizer
// and diarizer run against it with this Mac's models, exactly as they run on the
// client, so the client merges the rows back unchanged. Speaker identification stays
// on the client: the voiceprints never leave it. The summary is written there too,
// after identification, so it names people instead of "Speaker 2" (the automatic
// summary runs once per transcript pass). Exit 0 once the transcript is final;
// diarization is best effort. Nothing is printed: the
// output could hold meeting content and flowd discards it anyway. The percent
// done goes to <dir>/progress for flowd's handoff list: the transcript is the
// first 80, speaker labels the rest.

func argument(_ name: String) -> String? {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func descriptor(_ name: String) throws -> (ModelDescriptor, String) {
  // Pinned descriptors sit next to the binary, as for flowd-speech.
  let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  let data = try Data(contentsOf: directory.appendingPathComponent(name))
  return (
    try JSONDecoder().decode(ModelDescriptor.self, from: data),
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  )
}

/// Writes whole percents to `<dir>/progress`, atomically, each one once.
final class ProgressFile: @unchecked Sendable {
  private let url: URL
  private let lock = NSLock()
  private var last = -1

  init(directory: URL) { url = directory.appendingPathComponent("progress") }

  func report(_ fraction: Double) {
    let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
    lock.lock()
    defer { lock.unlock() }
    guard percent > last else { return }
    last = percent
    try? Data("\(percent)\n".utf8).write(to: url, options: .atomic)
  }
}

func process() async -> Int32 {
  guard let bundle = argument("--bundle").map({ URL(fileURLWithPath: $0, isDirectory: true) }),
    let meetingID = argument("--meeting").flatMap(UUID.init(uuidString:)),
    let models = argument("--models").map({ URL(fileURLWithPath: $0, isDirectory: true) }),
    let helper = argument("--helper").map({ URL(fileURLWithPath: $0) })
  else { return 64 }
  do {
    let (whisperDescriptor, whisperHash) = try descriptor("whisper-large-v3-turbo.json")
    let (diarizationDescriptor, diarizationHash) = try descriptor(
      "speaker-diarization-offline.json")
    FluidAudioDiarizerFactory.enableOfflineMode()
    // flowd-speech verified these files and holds their install lock while it runs.
    let whisper = LocalModelDescriptor(
      descriptor: whisperDescriptor,
      rootURL: models.appendingPathComponent("whisper-large-v3-turbo"))
    let diarization = LocalModelDescriptor(
      descriptor: diarizationDescriptor,
      rootURL: FluidAudioDiarizerFactory.installRoot(models: models))

    let history = try TranscriptionStore(
      path: bundle.appendingPathComponent("bundle.sqlite").path)
    let vocabulary = VocabularyStore(history: history)
    let root = MeetingStorageRoot(url: bundle)
    let meetings = MeetingStore(history: history, root: root)
    let transcripts = TranscriptStore(database: history.database)
    let clock = SystemMeetingClock()

    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: {
        try await FluidAudioDiarizerFactory(descriptor: diarization).makeRuntime()
      },
      voiceEmbeddingFactory: {
        try await FluidAudioVoiceEmbedderFactory(descriptor: diarization).makeRuntime()
      },
      meetingFactory: { language in
        let terms = (try? await vocabulary.snapshot().entries)?.filter(\.enabled).map(\.canonical)
        return try await WhisperMeetingRuntime.make(
          model: whisper, helperURL: helper, language: language, promptTerms: terms ?? []
        ) { helper, arguments, input, output in
          let process = Process()
          process.executableURL = helper
          process.arguments = arguments
          process.standardInput = input
          process.standardOutput = output
          process.standardError = FileHandle.nullDevice
          try process.run()
          return (process.processIdentifier, process)
        }
      },
      factory: { throw DictationFailure.modelUnavailable })
    await lifecycle.setKeepLoaded(true)

    // 1. The final transcript: the client's finalizer, resuming the client's pass.
    let finalizer = MeetingFinalizer(
      store: transcripts, meetings: meetings, storageRoot: root, lifecycle: lifecycle,
      inference: nil, vocabulary: vocabulary,
      identity: try TranscriptionPipelineIdentity(
        descriptor: whisperDescriptor, manifestHash: whisperHash, build: nil,
        engine: "whisper.cpp", windowSamples: 1_920_000),
      configuration: .turbo, defaultLanguage: { .defaultLanguage }, clock: clock)
    guard let row = try await transcripts.transcription(meetingID: meetingID) else { return 65 }
    let progress = ProgressFile(directory: bundle)
    progress.report(0)
    let outcome = try await finalizer.run(
      meetingID: meetingID, revision: row.revision,
      progress: { progress.report($0 * 0.8) })
    guard outcome.row.state == .final else { return 66 }

    // 2. Speaker labels. A failed run leaves the transcript usable.
    let speakers = SpeakerStore(history: history)
    let diarizer = MeetingDiarizer(
      speakers: speakers, transcripts: transcripts, meetings: meetings, storageRoot: root,
      lifecycle: lifecycle,
      identity: DiarizationIdentity(
        engine: "fluidaudio_offline_diarizer", modelID: diarizationDescriptor.modelID,
        modelRevision: diarizationDescriptor.sourceRevision, manifestHash: diarizationHash,
        pipelineVersion: DiarizationPipelineVersion.current),
      clock: clock)
    if (try? await diarizer.admit(meetingID: meetingID, trigger: .automatic, expectedRevision: nil))
      != nil
    {
      _ = await diarizer.run(
        meetingID: meetingID,
        progress: { done, planned in
          progress.report(0.8 + 0.2 * Double(done) / Double(max(planned, 1)))
        }, echoProfile: outcome.echoProfile)
    }
    await lifecycle.setKeepLoaded(false)

    // One file for the client to download.
    try await history.database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    return 0
  } catch {
    // stderr only, for someone running the tool by hand; flowd discards it.
    FileHandle.standardError.write(Data("flowd-meeting: \(error)\n".utf8))
    return 70
  }
}

exit(await process())
