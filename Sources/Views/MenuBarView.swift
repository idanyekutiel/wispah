import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Wispah Flow Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            if appState.screenRecordingEnabled && !appState.hasScreenRecordingPermission {
                Button {
                    appState.requestScreenCapturePermission()
                } label: {
                    Label("Screen Recording Permission Needed", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)

                Divider()
            }

            // Accessibility warning
            if !appState.hasAccessibility {
                Button {
                    appState.showAccessibilityAlert()
                } label: {
                    Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red)

                Divider()
            }

            // Status
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Button(appState.isRecording ? "Stop Recording" : "Start Dictating") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if !appState.lastTranscript.isEmpty {
                Button("Copy Last Transcription") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.lastTranscript, forType: .string)
                }
            }

            Divider()

            Menu("Microphone") {
                Button {
                    appState.selectedMicrophoneID = "default"
                } label: {
                    if appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty {
                        Text("✓ System Default")
                    } else {
                        Text("  System Default")
                    }
                }
                ForEach(appState.availableMicrophones) { device in
                    Button {
                        appState.selectedMicrophoneID = device.uid
                    } label: {
                        if appState.selectedMicrophoneID == device.uid {
                            Text("✓ \(device.name)")
                        } else {
                            Text("  \(device.name)")
                        }
                    }
                }
            }

            Button {
                appState.screenRecordingEnabled.toggle()
            } label: {
                Text(appState.screenRecordingEnabled ? "✓ Screen Context" : "  Screen Context")
            }

            Divider()

            if appState.collectStats {
                Button {
                    appState.selectedSettingsTab = .stats
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
            }

            Button {
                appState.selectedSettingsTab = .dictionary
                NotificationCenter.default.post(name: .showSettings, object: nil)
            } label: {
                Label("Dictionary", systemImage: "text.book.closed.fill")
            }

            Button {
                appState.selectedSettingsTab = .runLog
                NotificationCenter.default.post(name: .showSettings, object: nil)
            } label: {
                Label("Transcriptions", systemImage: "list.bullet.rectangle")
            }

            Button {
                appState.selectedSettingsTab = .general
                NotificationCenter.default.post(name: .showSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Re-run Setup...") {
                NotificationCenter.default.post(name: .showSetup, object: nil)
            }

            if appState.developerModeEnabled {
                Button("Debug Logs") {
                    NotificationCenter.default.post(name: .showDebugLogs, object: nil)
                }

                Button(appState.audioRecorder.isCapturing ? "Release Audio (Stop Mic)" : "Capture Audio (Claim Mic)") {
                    if appState.audioRecorder.isCapturing {
                        appState.audioRecorder.releaseAudio()
                    } else {
                        let deviceUID = appState.selectedMicrophoneID
                        appState.audioRecorder.captureAudio(deviceUID: deviceUID)
                    }
                }
                .disabled(appState.isRecording)

                Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                    appState.toggleDebugOverlay()
                }
            }

            if updateManager.updateAvailable {
                Divider()

                switch updateManager.updateStatus {
                case .downloading:
                    VStack(spacing: 4) {
                        Text("Downloading update... \(Int((updateManager.downloadProgress ?? 0) * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        ProgressView(value: updateManager.downloadProgress ?? 0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                case .installing, .readyToRelaunch:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing update...")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                default:
                    Button {
                        updateManager.showUpdateAlert()
                    } label: {
                        Label("Update Available", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                }
            }

            Divider()

            Button("Quit Wispah Flow") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}

extension Notification.Name {
    static let showSetup = Notification.Name("showSetup")
    static let showSettings = Notification.Name("showSettings")
    static let showDebugLogs = Notification.Name("showDebugLogs")
}
