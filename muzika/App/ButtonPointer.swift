import SwiftUI

extension View {
    func buttonPointer(when visible: Bool = true) -> some View {
        modifier(ButtonPointer(visible: visible))
    }
}

private struct ButtonPointer: ViewModifier {
    let visible: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled && visible ? .link : nil)
    }
}
