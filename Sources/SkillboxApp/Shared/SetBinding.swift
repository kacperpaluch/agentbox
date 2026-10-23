import SwiftUI
import SkillboxCore

/// A checkbox binding onto one member of a selection set.
///
/// `T` is `Sendable` because `Binding`'s accessors are `@Sendable` under Swift 6: without it the
/// captured value, the set and even `T.Type` each drew a concurrency warning here. Every caller
/// already passes `String`, `UUID` or `Tool`, so this constrains nothing in practice.
func setBinding<T: Hashable & Sendable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
    Binding(get: { set.wrappedValue.contains(value) }, set: { enabled in if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
}
