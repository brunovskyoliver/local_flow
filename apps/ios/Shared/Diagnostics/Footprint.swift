import Darwin

/// The process's `phys_footprint`, the figure iOS uses for extension memory limits
/// (constitution principle 13, SC-004). Read with `TASK_VM_INFO`; zero if the call fails.
enum Footprint {
  struct Reading: Equatable, Sendable {
    var current: UInt64
    var peak: UInt64
  }

  static func read() -> Reading {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return Reading(current: 0, peak: 0) }
    return Reading(
      current: UInt64(info.phys_footprint),
      peak: UInt64(max(0, info.ledger_phys_footprint_peak)))
  }
}
