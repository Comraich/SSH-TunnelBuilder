import SwiftUI

/// Shows a connection's live state as a coloured dot (or spinner) plus a label.
struct ConnectionIndicatorView: View {
    var connection: Connection

    private var statusColor: Color {
        switch connection.state {
        case .idle: return .gray
        case .connecting, .disconnecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch connection.state {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting..."
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if connection.state.isConnecting || connection.state.isDisconnecting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
