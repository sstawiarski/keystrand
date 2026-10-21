import RedisUI
import SettingsFeature
import SwiftUI

extension View {
    func shellStatusAlerts(_ center: ToastCenter) -> some View {
        errorAlerts(center)
    }
}

enum ActivityConnectionStatus: Equatable {
    case connecting
    case disconnected
    case failed
    case lost
    case connected

    static func make(phase: WindowContentPhase, isLost: Bool) -> ActivityConnectionStatus {
        switch phase {
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        case .failed: return .failed
        case .content: return isLost ? .lost : .connected
        }
    }

    nonisolated static func accessibilityLabel(_ status: ActivityConnectionStatus, isProduction: Bool) -> String {
        var parts = ["Database Activity"]
        if isProduction { parts.append("Production") }
        switch status {
        case .connecting: parts.append("Connecting")
        case .disconnected: parts.append("Disconnected")
        case .failed: parts.append("Connection Failed")
        case .lost: parts.append("Connection Lost")
        case .connected: break
        }

        return parts.joined(separator: ", ")
    }
}

/// Toolbar activity button showing production status and connection state or metrics. Opens database info.
struct DatabaseActivityView: View {
    let session: DatabaseSession
    /// A narrower activity view prevents toolbar items from clipping when the inspector is open.
    var isCompact = false
    @State private var showsInfo = false

    var body: some View {
        let connection = WindowConnectionModel.shared(for: session)
        let status = ActivityConnectionStatus.make(phase: connection.phase, isLost: connection.lostConnection != nil)
        HStack(spacing: 6) {
            Button { showsInfo = true } label: {
                HStack(spacing: 6) {
                    if session.isProduction {
                        Label("Production", systemImage: "exclamationmark.shield.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                            .fixedSize()
                        Text("·").foregroundStyle(.secondary)
                    }

                    ZStack {
                        OverviewBarView(session: session)
                            .opacity(status == .connected ? 1 : 0)
                        if status != .connected {
                            connectionLabel(status, connection: connection)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsInfo, arrowEdge: .bottom) { DatabaseInfoPopover(session: session) }
            .accessibilityLabel(ActivityConnectionStatus.accessibilityLabel(status, isProduction: session.isProduction))
            .help("Show Database Info")
            if status == .lost {
                Button("Reconnect") { Task { await connection.reconnect() } }
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minWidth: isCompact ? 160 : 200, idealWidth: isCompact ? 200 : 300, maxWidth: isCompact ? 320 : 560)
    }

    @ViewBuilder
    private func connectionLabel(_ status: ActivityConnectionStatus, connection: WindowConnectionModel) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .disconnected:
                Image(systemName: "bolt.horizontal.circle")
                Text("Disconnected")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Connection Failed")
            case .lost:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Connection Lost")
                    .help(connection.lostConnection.map { "\($0.title): \($0.message)" } ?? "")
            case .connected:
                EmptyView()
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}
