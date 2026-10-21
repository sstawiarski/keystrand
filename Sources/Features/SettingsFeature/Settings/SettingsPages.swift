import AppKit
import RedisUI
import SwiftUI

// MARK: - General

struct GeneralSettingsPage: View {
    @Bindable var model: SettingsViewModel
    let version = AppVersionInfo.current()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.theme) {
                    ForEach(SettingsViewModel.appearanceChoices, id: \.self) { theme in
                        Text(SettingsViewModel.appearanceTitle(theme)).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Picker("Format", selection: $model.formatSelection) {
                    ForEach(model.presetFormats, id: \.self) { format in
                        Text(format).tag(format)
                    }
                    Divider()
                    Text("Custom").tag(SettingsViewModel.customFormatTag)
                }
                .pickerStyle(.menu)

                if model.dateMode == .custom {
                    CustomDateFormatRow(model: model)
                }

                Picker("Time Zone", selection: $model.timezone) {
                    Text("System").tag(AppTimeZone.local)
                    Text("UTC").tag(AppTimeZone.utc)
                }
                .pickerStyle(.menu)

                LabeledContent("Preview") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let text = model.preview(at: context.date)
                        Text(text)
                            .monospacedDigit()
                            .foregroundStyle(text == DateFormatValidator.invalidPreview ? AnyShapeStyle(.red)
                                                                                         : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Date and Time")
            } footer: {
                Text("Custom formats use date-fns tokens such as yyyy, MM, dd, HH, mm, ss and SSS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hold ⌘Q to quit", isOn: $model.holdToQuit)
            } footer: {
                Text("A short press of ⌘Q shows a reminder instead of quitting. Quit in the menu bar or the Dock still quits at once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Quit when the last window closes", isOn: $model.quitAfterLastWindowClosed)
            } footer: {
                Text("Closing the last window quits Keystrand instead of leaving it running in the background. If a database is still connected, Keystrand asks first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: "\(version.version) (\(version.build))")
                    .textSelection(.enabled)
            } footer: {
                Text("MIT License · Help > Acknowledgements for third-party notices")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CustomDateFormatRow: View {
    @Bindable var model: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField("Custom Format", text: $model.customFormat, prompt: Text("HH:mm:ss d MMM yyyy"))
                .fontDesign(.monospaced)
                .focused($isFocused)
                .onChange(of: model.customFormat) { model.customFormatEdited() }
                .onSubmit { model.saveCustomFormat() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { model.saveCustomFormat() }
                }
                .help("Press Return to apply the format")
            if let error = model.customFormatError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Workbench

struct WorkbenchSettingsPage: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Empty the editor once commands run", isOn: $model.workbenchCleanup)
            }

            Section {
                LabeledContent("Commands per pipeline") {
                    TextField("Commands per pipeline", value: $model.pipelineBatchSize, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                }
            } header: {
                Text("Pipeline")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sets the batch size for pipelined commands. 0 or 1 sends each command separately.")
                        .foregroundStyle(.secondary)
                    Link("Learn About Pipelining", destination: SettingsLinks.pipelining)
                }
                .font(.footnote)
            }

            Section {
                Picker("Default results", selection: $model.resultsMode) {
                    Text("Separate").tag(ResultsMode.default)
                    Text("Grouped").tag(ResultsMode.group)
                    Text("Silent").tag(ResultsMode.silent)
                }
                .pickerStyle(.menu)
                Toggle("Show raw output", isOn: $model.rawMode)
            } header: {
                Text("Results")
            } footer: {
                Text("Grouped combines every command of a run into one result. Silent shows only errors.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettingsPage: View {
    @Bindable var model: SettingsViewModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                InlineMessage("Change these settings only if you understand their impact.", kind: .warning)
            }

            Section {
                LabeledContent("Keys to scan") {
                    TextField("Keys to scan", value: $model.scanThreshold, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 100)
                }
            } header: {
                Text("Browser")
            } footer: {
                Text("Keys scanned per iteration. Values below 500 are raised to 500.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Reset Settings…") { confirmReset = true }
                } label: {
                    Text("Reset settings")
                    Text("Restores General, Workbench, Browser and auto-refresh settings. Saved databases are not affected.")
                }
            }
        }
        .formStyle(.grouped)
        .destructiveConfirmation("Reset All Settings?", isPresented: $confirmReset,
                                 message: "General, Workbench, Browser and auto-refresh settings return to their defaults.",
                                 confirmTitle: "Reset") {
            model.resetAllSettings()
        }
    }
}

enum SettingsLinks {
    static let pipelining = URL(string: "https://redis.io/docs/latest/develop/use/pipelining/") ?? URL(fileURLWithPath: "/")
}
