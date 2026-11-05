import SwiftUI

extension View {
    /// A confirmation shown while `item` holds a value, built on the `isPresented:presenting:` form
    /// every supported SDK has. `confirmationDialog(_:item:)` exists only from the macOS 27 SDK, and
    /// the CI runners still build with Xcode 26.
    func confirmationDialog<Item, A: View, M: View>(_ title: String, presenting item: Binding<Item?>, @ViewBuilder actions: @escaping (Item) -> A, @ViewBuilder message: @escaping (Item) -> M) -> some View {
        confirmationDialog(title, isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), presenting: item.wrappedValue, actions: actions, message: message)
    }

    func confirmationDialog<Item, A: View>(_ title: String, presenting item: Binding<Item?>, @ViewBuilder actions: @escaping (Item) -> A) -> some View {
        confirmationDialog(title, isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), presenting: item.wrappedValue, actions: actions)
    }
}
