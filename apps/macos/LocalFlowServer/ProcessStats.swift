import Darwin
import Foundation

/// One server process: memory footprint (what Activity Monitor calls Memory) and start time.
struct ProcessRow: Identifiable, Equatable, Sendable {
  var name: String
  var pid: Int32
  var footprint: UInt64
  var started: Date?
  var id: Int32 { pid }
}

/// Reads memory and start time of the server's processes through libproc. Same-user
/// processes need no privileges.
enum ProcessStats {
  static func row(_ name: String, pid: Int32) -> ProcessRow? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    return ProcessRow(
      name: name, pid: pid, footprint: usage.ri_phys_footprint, started: started(pid))
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

  /// The server's processes: flowd and its two workers, MTPLX and oMLX.
  static func serverProcesses(flowd: Int32?, mtplx: Int32?) -> [ProcessRow] {
    var rows: [ProcessRow] = []
    if let flowd {
      rows += [row("flowd", pid: flowd)].compactMap { $0 }
      for child in children(of: flowd) {
        let name =
          arguments(child).dropFirst().first == "meeting" ? "Meeting worker" : "Speech worker"
        rows += [row(name, pid: child)].compactMap { $0 }
      }
    }
    if let mtplx { rows += [row("MTPLX", pid: mtplx)].compactMap { $0 } }
    // The oMLX app runs its server as a child that renames itself, so find it by parent.
    for app in pids(named: "oMLX") {
      rows += [row("oMLX app", pid: app)].compactMap { $0 }
      rows += children(of: app).compactMap { row("oMLX server", pid: $0) }
    }
    return rows
  }
}
