import Foundation

/// Typed extraction from `JSONSerialization` values. Booleans are `NSNumber` too,
/// so an integer field must reject them explicitly.
public enum JSONField {
  public static func int(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    guard let double = Double(exactly: number), double.rounded() == double,
      double >= Double(Int32.min), double <= Double(Int32.max)
    else { return nil }
    return Int(double)
  }
  public static func span(_ value: Any?) -> Int? {
    guard let value = int(value), value >= 0 else { return nil }
    return value
  }
  public static func identity(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty,
      string.utf8.count <= RewriteBounds.maximumIdentityBytes
    else { return nil }
    return string
  }
}
