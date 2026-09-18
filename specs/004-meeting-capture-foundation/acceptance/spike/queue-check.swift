import AVFoundation
import Foundation
let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
let semaphore = DispatchSemaphore(value: 0)
Task {
  var items: [AVPlayerItem] = []
  for url in urls {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    print("\(url.lastPathComponent) assetDuration=\(String(format: "%.3f", duration.seconds))")
    items.append(AVPlayerItem(asset: asset))
  }
  let player = AVQueuePlayer(items: items)
  player.volume = 0
  player.play()
  try await Task.sleep(for: .seconds(3))
  print("queueItems=\(player.items().count) currentItemStatus=\(player.currentItem?.status.rawValue ?? -1) rate=\(player.rate) currentTime=\(String(format: "%.2f", player.currentTime().seconds))")
  player.pause()
  semaphore.signal()
}
while semaphore.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
