import SwiftUI

/// Toolbar split button: a click refreshes; the menu holds "Auto Refresh" and "Refresh Every" (1, 2, 5, 10, 30,
/// 60 seconds, "Custom…"). The rate (1.0…999.9 s) persists per `postfix` in `settings.ui.autoRefreshRates`
/// (`keys`, `overview`, `slowlog`, a key type raw value, …).
public struct AutoRefreshMenu: View {
    public let postfix: String
    public var lastRefresh: Date?
    public var isLoading: Bool
    public var isDisabled: Bool
    public var enabledByDefault: Bool
    public var minimumRate: Double
    /// False keeps the on/off state in this view only (starting at `enabledByDefault`); the rate still persists.
    public var persistsEnabledState: Bool
    /// Skips auto-refresh ticks while true (for example while the window is hidden or a value is loading).
    public var isPaused: Bool
    public let onRefresh: () -> Void

    @Environment(SettingsStore.self) private var settings
    @State private var localEnabled: Bool?
    @State private var isEditingCustomRate = false
    @State private var customRateText = ""

    public init(postfix: String, lastRefresh: Date? = nil, isLoading: Bool = false, isDisabled: Bool = false,
                enabledByDefault: Bool = false, minimumRate: Double = 1.0, persistsEnabledState: Bool = true,
                isPaused: Bool = false, onRefresh: @escaping () -> Void) {
        self.postfix = postfix
        self.lastRefresh = lastRefresh
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.enabledByDefault = enabledByDefault
        self.minimumRate = minimumRate
        self.persistsEnabledState = persistsEnabledState
        self.isPaused = isPaused
        self.onRefresh = onRefresh
    }

    public static let presetRates: [Double] = [1, 2, 5, 10, 30, 60]

    private var isAuto: Bool {
        persistsEnabledState ? settings.ui.autoRefreshEnabled[postfix] ?? enabledByDefault : localEnabled ?? enabledByDefault
    }

    private func setAuto(_ enabled: Bool) {
        if persistsEnabledState { settings.ui.autoRefreshEnabled[postfix] = enabled } else { localEnabled = enabled }
    }

    private var rate: Double { max(settings.ui.autoRefreshRate(postfix), minimumRate) }

    public var body: some View {
        Menu {
            Toggle("Auto Refresh", isOn: Binding(get: { isAuto }, set: { setAuto($0) }))
            Picker("Refresh Every", selection: Binding(get: { rate }, set: { applyRate($0) })) {
                ForEach(Self.presetRates.filter { $0 >= minimumRate }, id: \.self) { value in
                    Text(Self.rateTitle(value)).tag(value)
                }
                if !Self.presetRates.contains(rate) {
                    Text("Custom (\(Self.rateTitle(rate)))").tag(rate)
                }
            }
            Button("Custom…") {
                customRateText = String(format: "%.1f", rate)
                isEditingCustomRate = true
            }
        } label: {
            if isLoading {
                Label { Text("Refresh") } icon: { ProgressView().controlSize(.small) }
            } else {
                Label("Refresh", systemImage: isAuto ? "timer" : "arrow.clockwise")
            }
        } primaryAction: {
            onRefresh()
        }
        .disabled(isDisabled)
        .help(Self.helpText(lastRefresh: lastRefresh, now: .now))
        .alert("Custom Refresh Rate", isPresented: $isEditingCustomRate) {
            TextField("Seconds", text: $customRateText)
            Button("Set") {
                if let value = Self.parseRate(customRateText, minimum: minimumRate) { applyRate(value) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a refresh rate between \(Self.rateTitle(minimumRate)) and 999.9 seconds.")
        }
        .task(id: "\(isAuto)-\(rate)-\(isDisabled)-\(isPaused)") {
            guard isAuto, !isDisabled, !isPaused else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(rate))
                if Task.isCancelled { break }
                onRefresh()
            }
        }
    }

    private func applyRate(_ value: Double) {
        settings.ui.autoRefreshRates[postfix] = Self.clamp(value, minimum: minimumRate)
    }

    nonisolated static func clamp(_ value: Double, minimum: Double) -> Double {
        min(max((value * 10).rounded() / 10, minimum), 999.9)
    }

    /// Parses "12.5" (one decimal kept) into a rate within minimum…999.9; nil when not a number.
    nonisolated public static func parseRate(_ text: String, minimum: Double = 1.0) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return clamp(value, minimum: minimum)
    }

    nonisolated public static func rateTitle(_ value: Double) -> String {
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return value == 1 ? "1 second" : "\(text) seconds"
    }

    nonisolated public static func helpText(lastRefresh: Date?, now: Date) -> String {
        guard let lastRefresh else { return "Refresh (⌘R)" }
        return "Refresh (⌘R) · Last refreshed \(relative(from: lastRefresh, now: now))"
    }

    /// "now" (< 5 s), "<n> s", "< 1 min", "<n> min".
    nonisolated public static func relative(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 120 { return "< 1 min" }
        return "\(seconds / 60) min"
    }
}
