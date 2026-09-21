import Foundation

/// FR-037: `1 MIN READ` is computed on the Mac from the rendered prose —
/// `ceil(words / 200)`, minimum one minute. No wire field carries a reading
/// time; the server is never asked for one.
enum ReadingTime {
  static func minutes(for model: MeetingAnalysisReadModel) -> Int {
    var words = count(model.summary.text)
    for topic in model.topics {
      words += count(topic.title) + count(topic.summary)
      for bullet in topic.bullets { words += count(bullet) }
    }
    for item in model.actionItems { words += count(item.text) }
    for list in [model.nextSteps, model.decisions, model.openQuestions, model.risks] {
      for item in list { words += count(item.text) }
    }
    return max(1, (words + 199) / 200)
  }

  private static func count(_ text: String) -> Int {
    text.split { $0 == " " || $0 == "\n" }.count
  }
}
