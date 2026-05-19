/**
 * [INPUT]: AnyObject reference
 * [OUTPUT]: Weak reference wrapper that can cross @Sendable closure boundaries
 * [POS]: Utility for preserving weak-capture semantics in DispatchQueue closures.
 */

final class WeakSendableReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
