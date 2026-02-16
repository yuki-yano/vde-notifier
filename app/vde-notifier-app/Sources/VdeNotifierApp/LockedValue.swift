import Foundation

final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ initialValue: Value) {
    value = initialValue
  }

  func set(_ newValue: Value) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
