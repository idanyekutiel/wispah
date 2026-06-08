import SwiftUI
import AVFoundation

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                let knobX = max(0, min(geo.size.width, geo.size.width * progress))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: knobX, height: 4)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: isScrubbing ? 12 : 9, height: isScrubbing ? 12 : 9)
                        .offset(x: knobX - (isScrubbing ? 6 : 4.5))
                        .animation(.easeOut(duration: 0.1), value: isScrubbing)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            seek(toFraction: value.location.x / geo.size.width, resume: false)
                        }
                        .onEnded { value in
                            isScrubbing = false
                            seek(toFraction: value.location.x / geo.size.width, resume: isPlaying)
                        }
                )
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            preparePlayer()
        }
        .onDisappear {
            teardownPlayer()
        }
    }

    /// Load the player up front (paused) so the scrubber works before first play.
    @discardableResult
    private func preparePlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        guard let p = try? AVAudioPlayer(contentsOf: audioURL) else { return nil }
        delegate.onFinish = {
            self.isPlaying = false
            self.stopProgressTimer()
            self.elapsed = 0
            self.player?.currentTime = 0
        }
        p.delegate = delegate
        p.prepareToPlay()
        player = p
        duration = p.duration
        return p
    }

    private func togglePlayback() {
        guard let p = preparePlayer() else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            p.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    /// Seek to a 0...1 fraction of the track, optionally resuming playback.
    private func seek(toFraction fraction: Double, resume: Bool) {
        guard let p = preparePlayer(), duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let time = clamped * duration
        p.currentTime = time
        elapsed = time
        if resume {
            p.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    private func teardownPlayer() {
        stopProgressTimer()
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard !isScrubbing, let p = player, p.isPlaying else { return }
            elapsed = p.currentTime
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
