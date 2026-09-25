import Foundation
import Observation

@MainActor @Observable
final class InsightsModel {
  private(set) var insights: UsageInsights?
  private(set) var loadError: String?
  @ObservationIgnored private let load: () async throws -> UsageInsights

  init(load: @escaping () async throws -> UsageInsights) {
    self.load = load
  }

  convenience init(store: TranscriptionStore) {
    self.init(load: { try await store.usageInsights() })
  }

  func refresh() async {
    do {
      insights = try await load()
      loadError = nil
    } catch is CancellationError {
    } catch {
      loadError = "Insights could not be loaded. Your transcriptions are unchanged."
    }
  }
}
