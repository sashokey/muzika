import SwiftUI

struct LibrarySearchField: View {
    let title: LocalizedStringKey
    let clearTitle: LocalizedStringKey
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var showsClearHelp = false
    let onSubmit: () -> Void
    var onClear: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                let clear = Button(clearTitle, systemImage: "xmark.circle.fill") {
                    query = ""
                    onClear()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .buttonPointer()
                .foregroundStyle(.secondary)
                if showsClearHelp {
                    clear.help(Text(clearTitle))
                } else {
                    clear
                }
            }
        }
        .padding(8)
        .liquidGlassHover(restingFill: .quaternary.opacity(0.5))
    }
}
