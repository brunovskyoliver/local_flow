import XCTest

final class LogLineTests: XCTestCase {
  func testRemoteOperationLine() {
    let line = LogLine(
      "flowd 2026/10/01 21:59:31 remote rewrite channel=115 user=1 device=1 op=2 wait_ms=0 duration_ms=542 code=ok"
    )
    XCTAssertTrue(line.parsed)
    XCTAssertEqual(line.subject, "remote rewrite")
    XCTAssertEqual(line.service, .rewrite)
    XCTAssertEqual(line.durationMS, 542)
    XCTAssertEqual(line.code, "ok")
    XCTAssertEqual(line.level, .info)
    XCTAssertFalse(line.meeting)
    let parts = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .second], from: line.date!)
    XCTAssertEqual(
      [parts.year, parts.month, parts.day, parts.hour, parts.second], [2026, 10, 1, 21, 31])
  }

  func testMeetingPrefixComesBeforeTheDate() {
    let line = LogLine(
      "flowd meeting 2026/10/01 21:22:20 speech job=3 kind=transcribe samples=1920000 duration_ms=11086 code=repetition"
    )
    XCTAssertTrue(line.meeting)
    XCTAssertEqual(line.service, .meetingWorker)
    XCTAssertEqual(line.level, .error)
    XCTAssertEqual(line["kind"], "transcribe")
  }

  func testHTTPHandlerLines() {
    let rewrite = LogLine(
      "flowd 2026/10/01 22:21:30 request_id=2555D1D4 input_bytes=17 context_bytes=181 output_bytes=17 duration_ms=704 code=succeeded"
    )
    XCTAssertEqual(rewrite.subject, "")
    XCTAssertEqual(rewrite.service, .rewrite)
    let analysis = LogLine(
      "flowd 2026/10/01 22:21:30 request_id=A run_id=B stage=chunk input_bytes=1 output_bytes=2 duration_ms=3 queue_ms=0 preemptions=0 attempts=1 model=localflow rejected=- code=succeeded detail=-"
    )
    XCTAssertEqual(analysis.service, .analysis)
    XCTAssertEqual(analysis["model"], "localflow")
  }

  func testQuotedValueKeepsSpaces() {
    let line = LogLine(#"flowd 2026/10/01 20:00:00 speech worker_exit="signal: killed" "#)
    XCTAssertEqual(line["worker_exit"], "signal: killed")
    XCTAssertEqual(line.level, .error)
  }

  func testLevels() {
    XCTAssertEqual(
      LogLine(
        "flowd 2026/10/01 20:00:00 remote channel=4 purpose=session event=rate_limited code=busy"
      ).level, .warning)
    XCTAssertEqual(
      LogLine("flowd 2026/10/01 20:00:00 speech busy user=1 channel=2 window=0 waiting=4").level,
      .warning)
    XCTAssertEqual(
      LogLine("flowd 2026/10/01 20:00:00 speech worker_state=restarting").level, .warning)
    XCTAssertEqual(LogLine("flowd 2026/10/01 20:00:00 speech worker_failure=crashed").level, .error)
    XCTAssertEqual(
      LogLine(
        "flowd 2026/10/01 20:00:00 remote analysis channel=1 user=1 device=1 op=1 code=internal"
      ).level, .error)
  }

  func testUnknownLinesStayRaw() {
    for raw in ["panic: runtime error", "flowd not-a-date here", ""] {
      let line = LogLine(raw)
      XCTAssertFalse(line.parsed)
      XCTAssertEqual(line.raw, raw)
      XCTAssertEqual(line.service, .other)
      XCTAssertTrue(line.fields.isEmpty)
    }
  }

  func testWorkerStatesResetWhenFlowdRestarts() {
    var states = WorkerStates()
    for raw in [
      "flowd 2026/10/01 20:02:36 speech worker_ready engine=FluidAudio model_id=parakeet booster=ctc110m-v1 worker_build=flowd-speech 1",
      "flowd meeting 2026/10/01 20:02:35 speech worker_ready engine=whisper.cpp model_id=ggerganov/whisper.cpp-large-v3-turbo model_revision=5359",
      "flowd 2026/10/01 20:02:36 speech worker_state=ready",
      "flowd meeting 2026/10/01 20:02:37 speech worker_state=unavailable",
    ] {
      states.apply(LogLine(raw))
    }
    XCTAssertEqual(states.speech, "ready")
    XCTAssertEqual(states.meeting, "unavailable")
    XCTAssertEqual(states.speechReady["model_id"], "parakeet")
    XCTAssertEqual(states.speechReady["worker_build"], "flowd-speech 1")
    XCTAssertEqual(states.meetingModels, ["whisper.cpp-large-v3-turbo (whisper.cpp)"])
    states.apply(LogLine("flowd 2026/10/01 21:00:00 version=0.3.0 listening=127.0.0.1:8091"))
    XCTAssertNil(states.speech)
    XCTAssertNil(states.meeting)
    states.apply(LogLine("flowd 2026/10/01 21:00:01 speech worker_state=starting"))
    XCTAssertEqual(states.speech, "starting")
    // worker_runtime is the model runtime, not the process state.
    states.apply(LogLine("flowd 2026/10/01 21:00:02 speech worker_runtime=active"))
    XCTAssertEqual(states.speech, "starting")
  }
}
