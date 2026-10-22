import Darwin
import Foundation

/// One server process. `footprint` is the physical footprint (what Activity Monitor calls
/// Memory); `resident` is RSS, which also counts shared pages such as mapped model files,
/// so neither column is an isolated model working set. `depth` is the distance from the
/// launch agent's process, for indenting helpers under their parent.
struct ProcessRow: Identifiable, Equatable, Sendable {
  var name: String
  var pid: Int32
  var footprint: UInt64
  var resident: UInt64 = 0
  var started: Date?
  var depth = 0
  var id: Int32 { pid }
}

/// Reads memory and start time of the server's processes through libproc. Same-user
/// processes need no privileges.
enum ProcessStats {
  /// The traversal bound below each launch agent's process: model helpers sit at most a
  /// few levels down (flowd → flowd-speech meeting → localflow-whisper-engine; launchd's
  /// shell wrapper → Python).
  static let maximumDepth = 4
  static let maximumDescendants = 64

  static func row(_ name: String, pid: Int32, depth: Int = 0) -> ProcessRow? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    return ProcessRow(
      name: name, pid: pid, footprint: usage.ri_phys_footprint,
      resident: usage.ri_resident_size, started: started(pid), depth: depth)
  }

  static func started(_ pid: Int32) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Date(
      timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
        + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
  }

  static func children(of pid: Int32) -> [Int32] {
    var pids = [Int32](repeating: 0, count: 64)
    let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
    return count > 0 ? Array(pids.prefix(Int(count))) : []
  }

  /// Every process below `root`, breadth first, with its depth. Bounded by depth and
  /// count, and a PID is visited once even if the listing changes during the walk.
  static func descendants(
    of root: Int32, maximumDepth: Int = maximumDepth, limit: Int = maximumDescendants,
    children: (Int32) -> [Int32] = children(of:)
  ) -> [(pid: Int32, depth: Int)] {
    var found: [(pid: Int32, depth: Int)] = []
    var seen: Set<Int32> = [root]
    var level = [root]
    var depth = 0
    while !level.isEmpty, depth < maximumDepth, found.count < limit {
      depth += 1
      var next: [Int32] = []
      for parent in level {
        for child in children(parent) where child > 0 && seen.insert(child).inserted {
          guard found.count < limit else { return found }
          found.append((child, depth))
          next.append(child)
        }
      }
      level = next
    }
    return found
  }

  /// A readable role for a server process from its executable and arguments.
  static func role(executable: String, arguments: [String]) -> String {
    // An unreadable path (another user's process, or one that just exited) is empty.
    let name = executable.isEmpty ? "" : URL(fileURLWithPath: executable).lastPathComponent
    switch name {
    case "flowd": return "flowd"
    case "flowd-speech":
      switch arguments.dropFirst().first {
      case "meeting": return "Meeting worker"
      case "provision": return "Model provisioning"
      default: return "Speech worker"
      }
    case "flowd-meeting": return "Meeting processor"
    case "localflow-whisper-engine": return "Whisper helper"
    case "localflow-mtplx": return "MTPLX wrapper"
    case "bash", "sh", "zsh": return "Shell (\(name))"
    case _ where name.hasPrefix("python") || name == "Python": return "Model service (Python)"
    case "": return "Process"
    default: return name
    }
  }

  static func executable(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return "" }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// PIDs whose process name (as `ps -c` shows it) is `name`.
  static func pids(named name: String) -> [Int32] {
    var pids = [Int32](repeating: 0, count: 4096)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { pid in
      var buffer = [CChar](repeating: 0, count: 256)
      return proc_name(pid, &buffer, UInt32(buffer.count)) > 0
        && String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          == name
    }
  }

  static func arguments(_ pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    return parseProcArgs(Array(buffer.prefix(size)))
  }

  /// KERN_PROCARGS2 is argc (Int32), the executable path, NUL padding, then argc
  /// NUL-terminated arguments and the environment, which is dropped.
  static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
    guard buffer.count > 4 else { return [] }
    let argc = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var i = 4
    while i < buffer.count, buffer[i] != 0 { i += 1 }  // executable path
    while i < buffer.count, buffer[i] == 0 { i += 1 }  // padding
    var out: [String] = []
    while out.count < argc, i < buffer.count {
      let end = buffer[i...].firstIndex(of: 0) ?? buffer.count
      out.append(String(decoding: buffer[i..<end], as: UTF8.self))
      i = end + 1
    }
    return out
  }

  /// Used and total swap, from vm.swapusage.
  static func swap() -> (used: UInt64, total: UInt64)? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return (usage.xsu_used, usage.xsu_total)
  }

  /// A launch agent's process and everything below it, each labelled by its role.
  static func tree(_ name: String, pid: Int32) -> [ProcessRow] {
    var rows = [row(name, pid: pid)].compactMap { $0 }
    for (child, depth) in descendants(of: pid) {
      let label = role(executable: executable(child), arguments: arguments(child))
      rows += [row(label, pid: child, depth: depth)].compactMap { $0 }
    }
    return rows
  }

  /// The server's processes: flowd with its workers and their model helpers, MTPLX with
  /// whatever its launch agent started, and oMLX.
  static func serverProcesses(flowd: Int32?, mtplx: Int32?) -> [ProcessRow] {
    var rows: [ProcessRow] = []
    if let flowd { rows += tree("flowd", pid: flowd) }
    if let mtplx { rows += tree("MTPLX", pid: mtplx) }
    // The oMLX app runs its server as a child that renames itself, so find it by parent.
    for app in pids(named: "oMLX") {
      rows += [row("oMLX app", pid: app)].compactMap { $0 }
      rows += descendants(of: app).compactMap { row("oMLX server", pid: $0.pid, depth: $0.depth) }
    }
    return rows
  }
}
