// Throwaway codec recoverability harness (Feature 004, T005).
//
//   swift codec-spike.swift record <adts|fmp4|m4a> <output> [seconds]
//   swift codec-spike.swift check <adts|fmp4|m4a> <file>
//
// `record` encodes a synthesized 1 kHz tone with noise at 48 kHz mono through the
// named writer, syncs every 5 s and prints "t=<s> bytes=<n> rss=<bytes>" once per
// second until killed. `check` opens the file through AVAudioFile and reports
// whether it is playable, its decoded duration and (for ADTS) the complete-frame
// count from a header scan. No microphone is opened: the property under test is
// the container's behaviour after `kill -9`, which does not depend on the source.
import AVFoundation
import Darwin
import Foundation

let args = CommandLine.arguments
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}
guard args.count >= 4 else { fail("usage: record|check <adts|fmp4|m4a> <path> [seconds]") }
let mode = args[1]
let writer = args[2]
let path = args[3]
let seconds = args.count > 4 ? Double(args[4]) ?? 60 : 60
let sampleRate = 48_000.0
let blockFrames: AVAudioFrameCount = 4_096
let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

func rss() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let status = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

func fileSize(_ path: String) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

var phase = 0.0
func fillTone(_ buffer: AVAudioPCMBuffer) {
  buffer.frameLength = blockFrames
  let data = buffer.floatChannelData![0]
  for i in 0..<Int(blockFrames) {
    data[i] = Float(sin(phase)) * 0.4 + Float.random(in: -0.02...0.02)
    phase += 2 * .pi * 1_000 / sampleRate
    if phase > 2 * .pi { phase -= 2 * .pi }
  }
}

func adtsHeader(payload: Int, channels: Int) -> [UInt8] {
  let length = 7 + payload
  return [
    0xFF, 0xF1,
    UInt8((1 << 6) | (3 << 2) | (channels >> 2)),
    UInt8(((channels & 3) << 6) | (length >> 11)),
    UInt8((length >> 3) & 0xFF),
    UInt8(((length & 7) << 5) | 0x1F),
    0xFC,
  ]
}

final class Progress {
  var bytes = 0
  var start = Date()
  var lastPrinted = -1
  func tick(_ path: String) {
    let elapsed = Int(Date().timeIntervalSince(start))
    if elapsed != lastPrinted {
      lastPrinted = elapsed
      print("t=\(elapsed) bytes=\(fileSize(path)) rss=\(rss())")
      fflush(stdout)
    }
  }
}

func makeConverter() -> AVAudioConverter {
  var description = AudioStreamBasicDescription(
    mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
    mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
    mReserved: 0)
  let aac = AVAudioFormat(streamDescription: &description)!
  let converter = AVAudioConverter(from: pcm, to: aac)!
  converter.bitRate = 64_000
  return converter
}

func recordADTS() throws {
  let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
  guard fd >= 0 else { fail("open failed errno=\(errno)") }
  let converter = makeConverter()
  let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: blockFrames)!
  let output = AVAudioCompressedBuffer(
    format: converter.outputFormat, packetCapacity: 8, maximumPacketSize: 1_536)
  let progress = Progress()
  var lastSync = Date()
  let deadline = Date().addingTimeInterval(seconds)
  let blockSeconds = Double(blockFrames) / sampleRate
  var produced = 0.0
  while Date() < deadline {
    fillTone(input)
    var supplied = false
    var error: NSError?
    repeat {
      output.packetCount = 0
      output.byteLength = 0
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if supplied {
          inputStatus.pointee = .noDataNow
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return input
      }
      guard status != .error, error == nil else { fail("convert failed") }
      let descriptions = output.packetDescriptions!
      var bytes = [UInt8]()
      for index in 0..<Int(output.packetCount) {
        let description = descriptions[index]
        let payload = Int(description.mDataByteSize)
        bytes.append(contentsOf: adtsHeader(payload: payload, channels: 1))
        let base = output.data.advanced(by: Int(description.mStartOffset))
        bytes.append(contentsOf: UnsafeBufferPointer(
          start: base.assumingMemoryBound(to: UInt8.self), count: payload))
      }
      if !bytes.isEmpty {
        var offset = 0
        while offset < bytes.count {
          let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
          guard n > 0 else { fail("write failed errno=\(errno)") }
          offset += n
        }
      }
      if output.packetCount < 8 { break }
    } while true
    produced += blockSeconds
    if Date().timeIntervalSince(lastSync) >= 5 {
      fsync(fd)
      lastSync = Date()
    }
    progress.tick(path)
    // Pace to real time so the kill points map to recorded seconds.
    let ahead = produced - Date().timeIntervalSince(progress.start)
    if ahead > 0 { usleep(UInt32(ahead * 1_000_000)) }
  }
  fsync(fd)
  close(fd)
}

func recordM4A() throws {
  let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
  ]
  let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
  let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: blockFrames)!
  let progress = Progress()
  let deadline = Date().addingTimeInterval(seconds)
  let blockSeconds = Double(blockFrames) / sampleRate
  var produced = 0.0
  while Date() < deadline {
    fillTone(input)
    try file.write(from: input)
    produced += blockSeconds
    progress.tick(path)
    let ahead = produced - Date().timeIntervalSince(progress.start)
    if ahead > 0 { usleep(UInt32(ahead * 1_000_000)) }
  }
}

func recordFMP4() throws {
  let url = URL(fileURLWithPath: path)
  let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
  assetWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
  assetWriter.shouldOptimizeForNetworkUse = false
  let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
  ]
  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
  input.expectsMediaDataInRealTime = true
  assetWriter.add(input)
  guard assetWriter.startWriting() else { fail("startWriting failed \(String(describing: assetWriter.error))") }
  assetWriter.startSession(atSourceTime: .zero)
  let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: blockFrames)!
  let progress = Progress()
  let deadline = Date().addingTimeInterval(seconds)
  let blockSeconds = Double(blockFrames) / sampleRate
  var produced = 0.0
  var frames: Int64 = 0
  while Date() < deadline {
    fillTone(buffer)
    var sampleBuffer: CMSampleBuffer?
    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: nil, asbd: pcm.streamDescription, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
    let time = CMTime(value: frames, timescale: Int32(sampleRate))
    CMSampleBufferCreate(
      allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
      refcon: nil, formatDescription: formatDescription, sampleCount: CMItemCount(blockFrames),
      sampleTimingEntryCount: 1,
      sampleTimingArray: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)],
      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
    CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
      bufferList: buffer.audioBufferList)
    while !input.isReadyForMoreMediaData { usleep(1_000) }
    input.append(sampleBuffer!)
    frames += Int64(blockFrames)
    produced += blockSeconds
    progress.tick(path)
    let ahead = produced - Date().timeIntervalSince(progress.start)
    if ahead > 0 { usleep(UInt32(ahead * 1_000_000)) }
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  assetWriter.finishWriting { done.signal() }
  done.wait()
}

func scanADTS(_ path: String) -> (frames: Int, completeBytes: Int, trailing: Int) {
  guard let data = FileManager.default.contents(atPath: path) else { return (0, 0, 0) }
  var offset = 0
  var frames = 0
  let bytes = [UInt8](data)
  while offset + 7 <= bytes.count {
    guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF6 == 0xF0 else { break }
    let length = (Int(bytes[offset + 3] & 3) << 11) | (Int(bytes[offset + 4]) << 3) | (Int(bytes[offset + 5]) >> 5)
    guard length >= 7, offset + length <= bytes.count else { break }
    offset += length
    frames += 1
  }
  return (frames, offset, bytes.count - offset)
}

func check() {
  let size = fileSize(path)
  var playable = false
  var durationSeconds = 0.0
  var note = ""
  do {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    durationSeconds = Double(file.length) / file.fileFormat.sampleRate
    // Decode the whole file in bounded blocks; a broken container fails here.
    let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)!
    var decoded: AVAudioFramePosition = 0
    while file.framePosition < file.length {
      try file.read(into: block)
      if block.frameLength == 0 { break }
      decoded += AVAudioFramePosition(block.frameLength)
    }
    playable = decoded > 0
    durationSeconds = Double(decoded) / file.processingFormat.sampleRate
  } catch {
    note = "open/read failed: \((error as NSError).code)"
  }
  var line = "writer=\(writer) file=\(path) bytes=\(size) playable=\(playable) seconds=\(String(format: "%.3f", durationSeconds))"
  if writer == "adts" {
    let scan = scanADTS(path)
    line += " completeFrames=\(scan.frames) completeBytes=\(scan.completeBytes) trailingBytes=\(scan.trailing)"
  }
  if !note.isEmpty { line += " note=\(note)" }
  print(line)
}

switch (mode, writer) {
case ("record", "adts"): try recordADTS()
case ("record", "m4a"): try recordM4A()
case ("record", "fmp4"): try recordFMP4()
case ("check", _): check()
default: fail("unknown mode/writer")
}
