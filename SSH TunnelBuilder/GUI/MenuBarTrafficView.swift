// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
//  MenuBarTrafficView.swift
//  SSH TunnelBuilder
//
//  Menu bar traffic indicator: two dots in the system menu bar — a TX dot that
//  blinks green while data is sent and an RX dot that blinks red while data is
//  received. The item is only present while at least one tunnel is connected.
//

import SwiftUI
import AppKit
import Observation

/// Samples the live byte counters of connected tunnels on a short interval and
/// exposes blink state for the menu bar dots. Runs entirely on the MainActor,
/// where the `Connection` byte counters are mutated, so reads are race-free.
@MainActor
@Observable
final class MenuBarTrafficMonitor {

    /// Whether any connection is currently connected. Drives menu bar visibility.
    private(set) var hasActiveConnection = false

    /// TX dot state — toggles each tick while bytes are being sent, off when idle.
    private(set) var transmitting = false

    /// RX dot state — toggles each tick while bytes are being received, off when idle.
    private(set) var receiving = false

    private let store: ConnectionStore
    private var lastBytesSent: Int64 = 0
    private var lastBytesReceived: Int64 = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Sampling interval. ~3 Hz gives a visibly blinking dot under sustained load
    /// without being distracting.
    private static let sampleInterval = Duration.milliseconds(300)

    init(store: ConnectionStore) {
        self.store = store
    }

    /// Begins polling. Safe to call more than once; only the first call starts a loop.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    /// Stops polling.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One sampling tick: refreshes visibility and computes blink state from the
    /// change in aggregate bytes since the previous tick.
    private func sample() {
        let active = store.connections.filter { $0.state.isActive }
        hasActiveConnection = !active.isEmpty

        let totalSent = active.reduce(Int64(0)) { $0 + $1.bytesSent }
        let totalReceived = active.reduce(Int64(0)) { $0 + $1.bytesReceived }

        // Toggle each tick while bytes keep arriving so the dot blinks under
        // continuous traffic; clear it when nothing moved this interval.
        transmitting = totalSent > lastBytesSent ? !transmitting : false
        receiving = totalReceived > lastBytesReceived ? !receiving : false

        // Record current totals as the new baseline. After a disconnect the
        // counters reset to 0, so the baseline follows them back down and a
        // reconnect blinks correctly from the first byte.
        lastBytesSent = totalSent
        lastBytesReceived = totalReceived
    }
}

/// The two-dot label shown in the menu bar.
struct MenuBarTrafficLabel: View {
    var monitor: MenuBarTrafficMonitor

    // Dim baseline colour for an inactive dot — visible but clearly "off".
    private let idleColor = Color.secondary.opacity(0.4)
    private let dotSize: CGFloat = 5

    var body: some View {
        // MenuBarExtra treats its label as a single status-item image: an HStack
        // of two Images clipped to one dot, custom Shapes and symbol-in-Text
        // rendered nothing. So we rasterise the indicator into one non-template
        // NSImage and hand that over — the one form the menu bar renders reliably,
        // with colours preserved (isTemplate = false stops the menu bar tinting it).
        Image(nsImage: renderedIndicator)
            .accessibilityLabel("SSH traffic: data sent and received indicators")
    }

    /// "SSH" stacked above the two coloured dots, rendered to a single bitmap.
    private var renderedIndicator: NSImage {
        // isTemplate = false means the image won't auto-adapt to the menu bar's
        // appearance, so resolve the "SSH" label's colour against the current
        // system appearance to keep it legible in both light and dark menu bars.
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let indicator = VStack(spacing: 1) {
            Text("SSH")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 3) {
                Circle()
                    .fill(monitor.transmitting ? Color.green : idleColor)
                    .frame(width: dotSize, height: dotSize)
                Circle()
                    .fill(monitor.receiving ? Color.red : idleColor)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .environment(\.colorScheme, isDark ? .dark : .light)

        let renderer = ImageRenderer(content: indicator)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        // Render as a real (coloured) image, not a template the menu bar recolours.
        image.isTemplate = false
        return image
    }
}

/// The dropdown shown when the menu bar item is clicked: one line per connected
/// tunnel with its cumulative sent/received totals, plus a button to bring the
/// main window back if it's been closed.
struct MenuBarTrafficContent: View {
    var store: ConnectionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = store.connections.filter { $0.state.isActive }
        if active.isEmpty {
            Text("No active connections")
        } else {
            ForEach(active) { connection in
                Text("\(connection.connectionInfo.name) — ↑ \(connection.bytesSent.formatted(.byteCount(style: .file)))  ↓ \(connection.bytesReceived.formatted(.byteCount(style: .file)))")
            }
        }

        Divider()

        Button("Show Main Window") {
            openWindow(id: "main")
        }
    }
}
