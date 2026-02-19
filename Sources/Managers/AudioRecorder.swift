import AVFoundation
import CoreAudio
import Foundation
import os.log

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        }
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let audioFileQueue = DispatchQueue(label: "com.idanyekutiel.wispah.audiofile")
    private var recordingStartTime: CFAbsoluteTime = 0
    private var firstBufferLogged = false
    private var bufferCount: Int = 0
    private var currentDeviceUID: String?
    private var storedInputFormat: AVAudioFormat?
    private var tapInstalled = false

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0
    /// Tracks time of last non-silent audio buffer for trailing silence trimming
    private var lastNonSilentTime: TimeInterval = 0
    private let silenceThresholdRMS: Float = 0.005
    /// Count of buffers with speech-level audio (above background noise)
    private var speechBufferCount: Int = 0
    private let speechThresholdRMS: Float = 0.015
    /// Minimum speech buffers required (~0.3s of speech at 4096-sample buffers / 48kHz)
    private let minSpeechBuffers: Int = 4
    /// Time of first and last speech-level audio (relative to recording start)
    private var firstSpeechTime: TimeInterval = 0
    private var lastSpeechTime: TimeInterval = 0

    /// Called on the audio thread when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?
    private var readyFired = false

    private func setupEngine(deviceUID: String? = nil) throws {
        // Tear down old engine if device changed
        if audioEngine != nil, currentDeviceUID != deviceUID {
            removeTap()
            audioEngine?.stop()
            audioEngine = nil
        }
        guard audioEngine == nil else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let engine = AVAudioEngine()
        os_log(.info, log: recordingLog, "AVAudioEngine created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        // Set specific input device if requested
        if let uid = deviceUID, !uid.isEmpty, uid != "default",
           let deviceID = AudioDevice.deviceID(forUID: uid) {
            os_log(.info, log: recordingLog, "device lookup resolved to %d for uid=%{public}@: %.3fms", deviceID, uid, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard let inputUnit = engine.inputNode.audioUnit else {
                throw AudioRecorderError.invalidInputFormat("Could not access audio input unit")
            }
            var id = deviceID
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        } else {
            os_log(.info, log: recordingLog, "using system default input device (uid=%{public}@)", deviceUID ?? "nil")
        }

        let inputNode = engine.inputNode
        os_log(.info, log: recordingLog, "inputNode accessed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        os_log(.info, log: recordingLog, "inputFormat retrieved (rate=%.0f, ch=%d): %.3fms", inputFormat.sampleRate, inputFormat.channelCount, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat("Invalid sample rate: \(inputFormat.sampleRate)")
        }
        guard inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("No input channels available")
        }

        storedInputFormat = inputFormat
        self.audioEngine = engine
        self.currentDeviceUID = deviceUID
    }

    /// Install audio tap on the engine's input node.
    private func installTap() {
        guard let engine = audioEngine, let inputFormat = storedInputFormat else { return }
        guard !tapInstalled else { return }

        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }

            self.bufferCount += 1

            // Check if this buffer has real audio
            var rms: Float = 0
            let frames = Int(buffer.frameLength)
            if frames > 0, let channelData = buffer.floatChannelData {
                let samples = channelData[0]
                var sum: Float = 0
                for i in 0..<frames { sum += samples[i] * samples[i] }
                rms = sqrtf(sum / Float(frames))
            }

            // Track last non-silent buffer for trailing silence trimming
            if rms > self.silenceThresholdRMS {
                self.lastNonSilentTime = CFAbsoluteTimeGetCurrent() - self.recordingStartTime
            }

            // Track buffers with speech-level audio
            if rms > self.speechThresholdRMS {
                self.speechBufferCount += 1
                let elapsed = CFAbsoluteTimeGetCurrent() - self.recordingStartTime
                if self.firstSpeechTime == 0 {
                    self.firstSpeechTime = elapsed
                }
                self.lastSpeechTime = elapsed
            }

            if self.bufferCount <= 40 {
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                os_log(.info, log: recordingLog, "buffer #%d at %.3fms, frames=%d, rms=%.6f", self.bufferCount, elapsed, buffer.frameLength, rms)
            }

            // Fire ready callback on first non-silent buffer
            if !self.readyFired && rms > 0 {
                self.readyFired = true
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
                self.onRecordingReady?()
            }

            self.audioFileQueue.sync {
                if let file = self.audioFile {
                    do {
                        try file.write(from: buffer)
                    } catch {
                        self.audioFile = nil
                    }
                }
            }
            self.computeAudioLevel(from: buffer)
        }
        tapInstalled = true
        os_log(.info, log: recordingLog, "tap installed")
    }

    /// Remove the audio tap from the engine's input node.
    private func removeTap() {
        guard tapInstalled, let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        os_log(.info, log: recordingLog, "tap removed")
    }

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        firstBufferLogged = false
        bufferCount = 0
        readyFired = false
        speechBufferCount = 0
        firstSpeechTime = 0
        lastSpeechTime = 0

        os_log(.info, log: recordingLog, "startRecording() entered, deviceUID=%{public}@", deviceUID ?? "nil")

        // Reuse existing engine if same device, otherwise build new one
        if let _ = audioEngine, currentDeviceUID == deviceUID {
            os_log(.info, log: recordingLog, "reusing existing engine: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        } else {
            try setupEngine(deviceUID: deviceUID)
        }

        // Reinstall tap (removed on previous stop) and start engine
        installTap()
        if let engine = audioEngine, !engine.isRunning {
            engine.prepare()
            os_log(.info, log: recordingLog, "engine prepared: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            try engine.start()
            os_log(.info, log: recordingLog, "engine started: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        guard let inputFormat = storedInputFormat else {
            throw AudioRecorderError.invalidInputFormat("No stored input format")
        }

        // Create a temp file to write audio to (AAC for much smaller file size)
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        self.tempFileURL = fileURL

        let newAudioFile: AVAudioFile
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            newAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: aacSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            // Fall back to WAV if AAC encoding isn't available
            os_log(.error, log: recordingLog, "AAC file creation failed, falling back to WAV: %{public}@", error.localizedDescription)
            let wavURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
            self.tempFileURL = wavURL
            let fallbackSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: inputFormat.isInterleaved ? 0 : 1,
            ]
            newAudioFile = try AVAudioFile(
                forWriting: wavURL,
                settings: fallbackSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: inputFormat.isInterleaved
            )
        }
        os_log(.info, log: recordingLog, "audio file created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        // Set audio file permissions to owner-only read/write
        if let audioPath = self.tempFileURL?.path {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioPath)
        }

        audioFileQueue.sync { self.audioFile = newAudioFile }
        DispatchQueue.main.async { self.isRecording = true }
        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// Duration (in seconds) of the recording up to the last non-silent audio.
    /// Use this to trim trailing silence before uploading.
    var lastNonSilentDuration: TimeInterval {
        // Add a small buffer (0.3s) to avoid cutting off speech tails
        return lastNonSilentTime > 0 ? lastNonSilentTime + 0.3 : 0
    }

    /// Whether the recording contained enough speech-level audio (not just background noise).
    /// Requires multiple consecutive speech-level buffers to filter out noise spikes.
    var detectedSpeech: Bool { speechBufferCount >= minSpeechBuffers }

    /// Time range of detected speech with small padding to preserve natural speech tails.
    /// Returns (start, end) in seconds from recording start, or nil if no speech detected.
    var speechTimeRange: (start: Double, end: Double)? {
        guard detectedSpeech else { return nil }
        let start = max(firstSpeechTime - 0.15, 0)  // small pad before first word
        let end = lastSpeechTime + 0.3               // pad after last word for tails
        return (start, end)
    }

    func stopRecording() -> URL? {
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received, speechBuffers=%d", elapsed, bufferCount, speechBufferCount)
        os_log(.info, log: recordingLog, "last non-silent audio at %.2fs", lastNonSilentTime)

        audioFileQueue.sync { audioFile = nil }
        DispatchQueue.main.async { self.isRecording = false }
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }

        // Remove tap + stop engine so mic is released and indicator goes away.
        // Engine is kept alive for fast reuse — only the tap is reinstalled on next start.
        removeTap()
        audioEngine?.stop()
        onRecordingReady = nil
        os_log(.info, log: recordingLog, "engine stopped, tap removed (mic released)")

        return tempFileURL
    }

    private func computeAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0.0
        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
        } else if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = Float(samples[i]) / Float(Int16.max)
                sumOfSquares += sample * sample
            }
        } else {
            return
        }

        let rms = sqrtf(sumOfSquares / Float(frames))

        // Logarithmic scaling for better sensitivity to normal speech levels
        // dB range: -50 (near-silence) to -10 (loud speech)
        let db = 20 * log10f(max(rms, 1e-6))
        let minDb: Float = -50
        let maxDb: Float = -10
        let scaled = max(0, min(1, (db - minDb) / (maxDb - minDb)))

        // Fast attack, slower release — follows speech dynamics closely
        if scaled > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.3 + scaled * 0.7
        } else {
            smoothedLevel = smoothedLevel * 0.6 + scaled * 0.4
        }

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedLevel
        }
    }

    /// Downsample audio to 16KHz mono AAC, skip leading noise, and optionally trim trailing silence.
    /// Returns the URL of the preprocessed file (caller should clean up).
    func preprocessAudio(inputURL: URL, trimToSeconds: Double? = nil, skipLeadingSeconds: Double = 0) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("upload_\(UUID().uuidString).m4a")

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioRecorderError.invalidInputFormat("No audio track found")
        }

        // Trim to speech boundaries (skips key click noise at start/end)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        let startSeconds = min(skipLeadingSeconds, totalSeconds * 0.25) // never skip more than 25%
        let endSeconds: Double
        if let trim = trimToSeconds, trim > 0, trim < totalSeconds {
            endSeconds = trim
        } else {
            endSeconds = totalSeconds
        }
        if startSeconds > 0 || endSeconds < totalSeconds {
            let safeEnd = max(endSeconds, startSeconds + 0.1) // always keep at least 0.1s
            let startTime = CMTime(seconds: startSeconds, preferredTimescale: 44100)
            let endTime = CMTime(seconds: safeEnd, preferredTimescale: 44100)
            reader.timeRange = CMTimeRange(start: startTime, end: endTime)
            os_log(.info, log: recordingLog, "preprocessing: speech range %.2fs-%.2fs of %.2fs total", startSeconds, safeEnd, totalSeconds)
        }

        // Reader: decode to 16KHz mono PCM
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // Writer: encode as 16KHz mono AAC
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // nonisolated(unsafe) silences Sendable warnings — these are only accessed
        // sequentially on the writer's serial queue, so there's no data race.
        nonisolated(unsafe) let writerInputRef = writerInput
        nonisolated(unsafe) let readerOutputRef = readerOutput

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInputRef.requestMediaDataWhenReady(on: DispatchQueue(label: "com.idanyekutiel.wispah.audiopreprocess")) {
                while writerInputRef.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutputRef.copyNextSampleBuffer() {
                        writerInputRef.append(sampleBuffer)
                    } else {
                        writerInputRef.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
            throw AudioRecorderError.invalidInputFormat("Audio preprocessing failed: \(errorMsg)")
        }

        // Set preprocessed audio file permissions to owner-only read/write
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)

        os_log(.info, log: recordingLog, "preprocessed audio: %{public}@", outputURL.lastPathComponent)
        return outputURL
    }

    /// Whether the audio engine is actively capturing (for debug UI)
    var isCapturing: Bool {
        audioEngine?.isRunning ?? false
    }

    /// Forcefully start the audio engine to claim the mic (debug: triggers BT profile switch).
    func captureAudio(deviceUID: String? = nil) {
        do {
            if audioEngine == nil || currentDeviceUID != deviceUID {
                try setupEngine(deviceUID: deviceUID)
            }
            installTap()
            if let engine = audioEngine, !engine.isRunning {
                engine.prepare()
                try engine.start()
                os_log(.info, log: recordingLog, "captureAudio: engine started (mic claimed)")
            }
        } catch {
            os_log(.error, log: recordingLog, "captureAudio failed: %{public}@", error.localizedDescription)
        }
    }

    /// Forcefully tear down the audio engine to release all mic claims.
    /// Use when Bluetooth headphones are stuck in low-quality mode.
    func releaseAudio() {
        removeTap()
        if let engine = audioEngine {
            engine.stop()
            os_log(.info, log: recordingLog, "releaseAudio: engine fully torn down")
        }
        audioEngine = nil
        currentDeviceUID = nil
        storedInputFormat = nil
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
