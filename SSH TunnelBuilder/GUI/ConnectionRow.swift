import SwiftUI

struct ConnectionRow: View {
    /// Take only the field the row renders, so the row invalidates when the
    /// name changes rather than on any change to the whole `connectionInfo`.
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
