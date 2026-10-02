import AVFAudio
import LocalFlowSpeech
import SwiftUI

/// Readings for the device acceptance runs (T059, T081, SC-004, quickstart §10). The
/// keyboard reports its own footprint through `keyboard-status.json`, because the app
/// cannot measure another process.
struct DiagnosticsView: View {
  static let enabledKey = "diagnostics.enabled"

  let app: PhoneApp
  @State private var keyboard: KeyboardStatusFile?
  @State private var delivery: DeliveryFile?
  @State private var footprint = Footprint.read()
  @State private var lifecycle: ModelLifecycleCoordinator.Snapshot?
  @State private var hasGroup = true
  @State private var fixtureStatus: String?
  @State private var controlStopToResult: TimeInterval?

  var body: some View {
    Form {
      Section {
        if !hasGroup {
          Text("No App Group in this build.").foregroundStyle(SottoPalette.muted)
        } else if let keyboard {
          LabeledContent("At last report", value: Self.megabytes(keyboard.footprintBytes))
          LabeledContent("Peak", value: Self.megabytes(keyboard.peakFootprintBytes))
          LabeledContent("Peak at rest", value: Self.megabytes(keyboard.footprintRestBytes))
          LabeledContent(
            "Peak while listening", value: Self.megabytes(keyboard.footprintListeningBytes))
          LabeledContent("Reported") {
            Text(Date(timeIntervalSince1970: Double(keyboard.lastSeen) / 1000), style: .relative)
              + Text(" ago")
          }
        } else {
          Text("Not reported yet: open the LocalFlow keyboard with Full Access on.")
            .foregroundStyle(SottoPalette.muted)
        }
      } header: {
        Text("Keyboard memory")
      } footer: {
        Text(
          "The keyboard reports when it appears, 3 seconds later (at rest), when it is "
            + "dismissed, and when a per-surface peak rises. Peak is the most the current "
            + "keyboard process has used; the rest and listening peaks are sampled once a "
            + "second while the keys or the listening view are up.")
      }
      Section("App memory") {
        LabeledContent("Now", value: Self.megabytes(footprint.current))
        LabeledContent("Peak", value: Self.megabytes(footprint.peak))
      }
      Section("Model") {
        if let lifecycle {
          LabeledContent("State", value: String(describing: lifecycle.state))
          LabeledContent("Loaded", value: lifecycle.loaded ? "Yes" : "No")
          LabeledContent("Leased", value: lifecycle.leased ? "Yes" : "No")
        }
        LabeledContent("Kept ready by", value: holders)
      }
      Section {
        LabeledContent("Stop", value: Self.time(app.controller?.lastStopAt))
        LabeledContent("Result", value: Self.time(app.controller?.lastResultAt))
        LabeledContent("Delivery", value: Self.time(deliveryDate))
        LabeledContent("Control stop → result", value: Self.seconds(controlStopToResult))
      } header: {
        Text("Last dictation")
      } footer: {
        Text(
          "Delivery is the keyboard's time for the same dictation; in-app notes have none. "
            + "Control stop → result is for the last dictation from the control, Action "
            + "Button or Shortcuts since LocalFlow started.")
      }
      #if DEBUG
        Section {
          Button("Transcribe fixture", action: transcribeFixtures)
            .disabled(fixtureStatus == "Transcribing…")
          if let fixtureStatus { Text(fixtureStatus).foregroundStyle(SottoPalette.muted) }
        } footer: {
          Text(
            "Transcribes every audio file in the app's Documents (copied in with Xcode's "
              + "device file sharing) and writes <name>.txt next to it.")
        }
      #endif
      Section {
        Button("Refresh", action: refresh)
      }
    }
    .navigationTitle("Diagnostics")
    .onAppear(perform: refresh)
  }

  private var holders: String {
    let holders = app.services?.keepReady.holders ?? []
    guard !holders.isEmpty else { return "Nothing" }
    return holders.map { $0 == .session ? "Session" : "Dictate screen" }.sorted()
      .joined(separator: ", ")
  }

  private var deliveryDate: Date? {
    guard let delivery, delivery.dictationID == app.controller?.lastResultID else { return nil }
    return Date(timeIntervalSince1970: Double(delivery.at) / 1000)
  }

  private func refresh() {
    let store = HandoffStore.group()
    hasGroup = store != nil
    keyboard = store?.read(KeyboardStatusFile.self, .keyboardStatus)
    delivery = store?.read(DeliveryFile.self, .delivery)
    footprint = Footprint.read()
    controlStopToResult = app.intents?.lastControlStopToResult
    Task { lifecycle = await app.services?.lifecycle.snapshot() }
  }

  static func megabytes(_ bytes: UInt64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  static func seconds(_ interval: TimeInterval?) -> String {
    interval.map { String(format: "%.2f s", $0) } ?? "—"
  }

  static func time(_ date: Date?) -> String {
    date?.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))) ?? "—"
  }

  #if DEBUG
    private func transcribeFixtures() {
      guard let services = app.services else { return }
      fixtureStatus = "Transcribing…"
      Task { fixtureStatus = await FixtureTranscription.run(services) }
    }
  #endif
}

#if DEBUG
  /// SC-003 parity: the phone's production pipeline over fixture files (quickstart §8).
  @MainActor
  enum FixtureTranscription {
    static func run(_ services: PhoneServices) async -> String {
      guard services.model.state == .ready else { return "The speech model isn't ready." }
      let audio = ["wav", "caf", "m4a", "flac", "aif", "aiff"]
      let files =
        ((try? FileManager.default.contentsOfDirectory(
          at: URL.documentsDirectory, includingPropertiesForKeys: nil)) ?? [])
        .filter { audio.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      var written = 0
      for file in files {
        do {
          let spool = try AudioSpool(
            rootDirectory: services.paths.temporaryAudio, sessionID: UUID(),
            maximumBytes: PhoneServices.spoolBytes)
          let samples = try decode(file, into: spool)
          let output = try await services.pipeline.run(
            spool: spool, sampleCount: samples, dictationID: UUID(), stopReason: .keyRelease)
          // One trailing newline, as the Mac script writes (quickstart §8).
          try (output.text + "\n").write(
            to: file.deletingPathExtension().appendingPathExtension("txt"), atomically: true,
            encoding: .utf8)
          written += 1
        } catch {
          continue
        }
      }
      return "Wrote \(written) of \(files.count) transcripts."
    }

    /// Any readable audio file as 16 kHz mono Float32, in spool-sized chunks.
    private static func decode(_ url: URL, into spool: AudioSpool) throws -> Int {
      let input = try AVAudioFile(forReading: url)
      guard
        let target = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: input.processingFormat, to: target),
        let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4_096),
        let output = AVAudioPCMBuffer(
          pcmFormat: target, frameCapacity: AVAudioFrameCount(AudioSpool.maximumAppendSamples))
      else { throw CocoaError(.fileReadCorruptFile) }
      var finished = false
      while !finished {
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
          do {
            try input.read(into: source)
          } catch {
            source.frameLength = 0
          }
          guard source.frameLength > 0 else {
            inputStatus.pointee = .endOfStream
            return nil
          }
          inputStatus.pointee = .haveData
          return source
        }
        if let error { throw error }
        if let channel = output.floatChannelData?[0], output.frameLength > 0 {
          do {
            try spool.append(
              normalizedSamples: UnsafeBufferPointer(
                start: channel, count: Int(output.frameLength)))
          } catch AudioSpoolError.capacityExceeded {
            break
          }
        }
        finished = status == .endOfStream || status == .error
      }
      return spool.bytesWritten / MemoryLayout<Float>.stride
    }
  }
#endif
