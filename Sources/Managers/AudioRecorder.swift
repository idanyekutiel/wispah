import AVFoundation
import Foundation
import os.log

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case startupTimedOut
    case captureSessionError(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        case .startupTimedOut:
            return "Audio input did not produce data in time."
        case .captureSessionError(let details):
            return "Audio capture failed: \(details)"
        }
    }
}

/// Indicates whether `startRecording` used the requested device or fell back to the system default.
struct RecordingStartResult {
    let usedFallback: Bool
    let deviceUID: String?
}

final class AudioRecorder: NSObject, ObservableObject {
    private let captureQueue = DispatchQueue(label: "com.idanyekutiel.wispah.capture")
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioFileOutput: AVCaptureAudioFileOutput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var tempFileURL: URL?
    private var fileOutputType: AVFileType = .caf
    private var currentDeviceUID: String?
    private var firstSampleTimestamp: CMTime?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?
    private let startupLock = NSLock()
    private var startupSemaphore: DispatchSemaphore?
    private var startupError: Error?
    private var startupResolved = false
    private let fileRecordingLock = NSLock()
    private var fileRecordingSemaphore: DispatchSemaphore?
    private var fileRecordingResolved = false
    private var fileRecordingError: Error?
    private var finishedRecordingURL: URL?
    private var recordingStartTime: CFAbsoluteTime = 0

    // MARK: - Thread-safe audio state

    /// Lock protecting mutable audio analysis state shared with the capture queue.
    private let tapLock = NSLock()
    private var bufferCount: Int = 0
    private var speechBufferCount: Int = 0
    private var readyFired = false
    private var firstSpeechTime: TimeInterval = 0
    private var lastSpeechTime: TimeInterval = 0
    private var lastNonSilentTime: TimeInterval = 0
    private var smoothedLevel: Float = 0.0

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    private let silenceThresholdRMS: Float = 0.005
    private let speechThresholdRMS: Float = 0.015
    /// Minimum speech buffers required (~0.3s of speech at 4096-sample buffers / 48kHz)
    private let minSpeechBuffers: Int = 4
    private let startupTimeout: TimeInterval = 2.0

    /// Called once capture is alive and a real audio buffer has arrived.
    var onRecordingReady: (() -> Void)?

    /// Called when a mid-recording error occurs (for example, capture device disconnect).
    /// The error message is passed as the parameter. Called on the main queue.
    var onRecordingError: ((String) -> Void)?

    // MARK: - Reset audio state

    private func resetTapState() {
        tapLock.lock()
        defer { tapLock.unlock() }
        bufferCount = 0
        speechBufferCount = 0
        readyFired = false
        firstSpeechTime = 0
        lastSpeechTime = 0
        lastNonSilentTime = 0
        smoothedLevel = 0.0
    }

    // MARK: - Startup synchronization

    private func prepareForStartupWait() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        startupLock.lock()
        startupSemaphore = semaphore
        startupError = nil
        startupResolved = false
        startupLock.unlock()
        return semaphore
    }

    private func resolveStartup(error: Error?) {
        startupLock.lock()
        guard !startupResolved else {
            startupLock.unlock()
            return
        }
        startupResolved = true
        startupError = error
        let semaphore = startupSemaphore
        startupSemaphore = nil
        startupLock.unlock()
        semaphore?.signal()
    }

    private func finishStartupWait(_ semaphore: DispatchSemaphore) throws {
        let waitResult = semaphore.wait(timeout: .now() + startupTimeout)

        startupLock.lock()
        let error = startupError
        let resolved = startupResolved
        if startupSemaphore === semaphore {
            startupSemaphore = nil
        }
        startupLock.unlock()

        if let error {
            throw error
        }
        if waitResult == .timedOut || !resolved {
            throw AudioRecorderError.startupTimedOut
        }
    }

    private func prepareForFileRecordingWait() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        fileRecordingLock.lock()
        fileRecordingSemaphore = semaphore
        fileRecordingResolved = false
        fileRecordingError = nil
        finishedRecordingURL = nil
        fileRecordingLock.unlock()
        return semaphore
    }

    private func resolveFileRecording(url: URL?, error: Error?) {
        fileRecordingLock.lock()
        guard !fileRecordingResolved else {
            fileRecordingLock.unlock()
            return
        }
        fileRecordingResolved = true
        finishedRecordingURL = url
        fileRecordingError = error
        let semaphore = fileRecordingSemaphore
        fileRecordingSemaphore = nil
        fileRecordingLock.unlock()
        semaphore?.signal()
    }

    private func finishFileRecordingWait(_ semaphore: DispatchSemaphore) throws -> URL {
        var waitResult: DispatchTimeoutResult = .timedOut
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                fileRecordingLock.lock()
                let resolved = fileRecordingResolved
                fileRecordingLock.unlock()
                if resolved {
                    waitResult = .success
                    break
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            waitResult = semaphore.wait(timeout: .now() + 15)
        }

        fileRecordingLock.lock()
        let error = fileRecordingError
        let resolved = fileRecordingResolved
        let url = finishedRecordingURL
        if fileRecordingSemaphore === semaphore {
            fileRecordingSemaphore = nil
        }
        fileRecordingLock.unlock()

        if let error {
            throw error
        }
        guard waitResult == .success, resolved, let url else {
            throw AudioRecorderError.captureSessionError("Audio file did not finish writing in time")
        }
        return url
    }

    // MARK: - Capture lifecycle

    private func removeObservers() {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        if let observer = deviceDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceDisconnectObserver = nil
        }
    }

    private func tearDownCapture(cancelWriter: Bool) {
        removeObservers()

        if let output = audioOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
        }

        if cancelWriter, let fileOutput = audioFileOutput, fileOutput.isRecording {
            fileOutput.stopRecording()
        }

        if let session = captureSession, session.isRunning {
            session.stopRunning()
            os_log(.info, log: recordingLog, "capture session stopped")
        }

        captureSession = nil
        audioOutput = nil
        audioFileOutput = nil
        audioDeviceInput = nil
        currentDeviceUID = nil
        firstSampleTimestamp = nil
    }

    private func registerObservers(for session: AVCaptureSession, deviceUID: String) {
        removeObservers()

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = nsError?.localizedDescription ?? "Unknown runtime error"
            self?.handleCaptureFailure(AudioRecorderError.captureSessionError(message))
        }

        deviceDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == deviceUID else { return }

            self.handleCaptureFailure(
                AudioRecorderError.captureSessionError("Selected microphone disconnected")
            )
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        os_log(.error, log: recordingLog, "audio capture failure: %{public}@", error.localizedDescription)
        resolveStartup(error: error)

        if isRecording {
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingError?(error.localizedDescription)
            }
        }
    }

    private func recordingFileType() -> AVFileType {
        let supportedTypes = Set(AVCaptureAudioFileOutput.availableOutputFileTypes())
        if supportedTypes.contains(.caf) {
            return .caf
        }
        if supportedTypes.contains(.wav) {
            return .wav
        }
        if supportedTypes.contains(.aiff) {
            return .aiff
        }
        return AVCaptureAudioFileOutput.availableOutputFileTypes().first ?? .caf
    }

    private func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .caf:
            return "caf"
        case .wav:
            return "wav"
        case .aiff:
            return "aiff"
        case .m4a:
            return "m4a"
        default:
            return "caf"
        }
    }

    private func prepareOutputURL(for fileType: AVFileType) throws -> URL {
        if let existingURL = tempFileURL {
            try? FileManager.default.removeItem(at: existingURL)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(for: fileType))
        tempFileURL = fileURL
        return fileURL
    }

    private func buildCaptureSession(for device: AVCaptureDevice, outputURL: URL) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureSessionError("Could not add microphone input")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = normalizedCaptureAudioSettings()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureSessionError("Could not add audio output")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)

        let fileOutput = AVCaptureAudioFileOutput()
        fileOutput.audioSettings = nil
        guard session.canAddOutput(fileOutput) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureSessionError("Could not add audio file output")
        }
        session.addOutput(fileOutput)

        session.commitConfiguration()

        captureSession = session
        audioDeviceInput = input
        audioOutput = output
        audioFileOutput = fileOutput
        currentDeviceUID = device.uniqueID
        firstSampleTimestamp = nil

        registerObservers(for: session, deviceUID: device.uniqueID)
        session.startRunning()

        guard session.isRunning else {
            throw AudioRecorderError.captureSessionError("Capture session failed to start")
        }

        fileOutput.startRecording(to: outputURL, outputFileType: fileOutputType, recordingDelegate: self)
        os_log(.info, log: recordingLog, "capture session started for %{public}@", device.uniqueID)
    }

    private func normalizedCaptureAudioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func elapsedSeconds(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let firstSampleTimestamp else { return 0 }
        let elapsed = CMTimeSubtract(timestamp, firstSampleTimestamp)
        return max(CMTimeGetSeconds(elapsed), 0)
    }

    private func rms(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return 0 }

        let isFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)

        var sum: Double = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }

            if isFloat && streamDescription.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
                sampleCount += count
            } else if isSignedInteger && streamDescription.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                let scale = Double(Int16.max)
                for index in 0..<count {
                    let sample = Double(samples[index]) / scale
                    sum += sample * sample
                }
                sampleCount += count
            } else if isSignedInteger && streamDescription.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: count)
                let scale = Double(Int32.max)
                for index in 0..<count {
                    let sample = Double(samples[index]) / scale
                    sum += sample * sample
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sum / Double(sampleCount)))
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if firstSampleTimestamp == nil {
            firstSampleTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        let rmsValue = rms(from: sampleBuffer)
        let elapsed = elapsedSeconds(for: sampleBuffer)
        var shouldFireReady = false
        var currentBufferCount = 0

        tapLock.lock()
        bufferCount += 1
        currentBufferCount = bufferCount

        if rmsValue > silenceThresholdRMS {
            lastNonSilentTime = elapsed
        }

        if rmsValue > speechThresholdRMS {
            speechBufferCount += 1
            if firstSpeechTime == 0 {
                firstSpeechTime = elapsed
            }
            lastSpeechTime = elapsed
        }

        if !readyFired {
            readyFired = true
            shouldFireReady = true
        }
        tapLock.unlock()

        if currentBufferCount <= 20 {
            os_log(.info, log: recordingLog, "sample #%d at %.3fms, rms=%.6f", currentBufferCount, elapsed * 1000, rmsValue)
        }

        if shouldFireReady {
            resolveStartup(error: nil)
            os_log(.info, log: recordingLog, "first audio buffer received — recording ready")
            onRecordingReady?()
        }

        computeAudioLevel(rms: rmsValue)
    }

    private func resolveCaptureDevice(for selectionUID: String?) -> AVCaptureDevice? {
        AudioDevice.captureDevice(forSelectionUID: selectionUID)
    }

    private func attemptStartRecording(selectionUID: String?) throws -> String? {
        resetTapState()
        firstSampleTimestamp = nil

        guard let captureDevice = resolveCaptureDevice(for: selectionUID) else {
            throw AudioRecorderError.missingInputDevice
        }

        fileOutputType = recordingFileType()
        let outputURL = try prepareOutputURL(for: fileOutputType)
        let startupSemaphore = prepareForStartupWait()

        do {
            try captureQueue.sync {
                tearDownCapture(cancelWriter: true)
                try buildCaptureSession(for: captureDevice, outputURL: outputURL)
            }
        } catch {
            resolveStartup(error: error)
            captureQueue.sync {
                tearDownCapture(cancelWriter: true)
            }
            throw error
        }

        do {
            try finishStartupWait(startupSemaphore)
        } catch {
            captureQueue.sync {
                tearDownCapture(cancelWriter: true)
            }
            throw error
        }

        return captureDevice.uniqueID
    }

    // MARK: - Start / Stop recording

    func startRecording(deviceUID: String? = nil) throws -> RecordingStartResult {
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered, deviceUID=%{public}@", deviceUID ?? "nil")

        let normalizedSelection = AudioDevice.normalizedSelectionUID(deviceUID)
        let shouldRetryWithDefault = normalizedSelection != nil && normalizedSelection != AudioDevice.systemDefaultSelectionUID

        do {
            let resolvedDeviceUID = try attemptStartRecording(selectionUID: normalizedSelection)
            DispatchQueue.main.async { self.isRecording = true }
            return RecordingStartResult(usedFallback: false, deviceUID: resolvedDeviceUID)
        } catch {
            guard shouldRetryWithDefault else { throw error }

            os_log(.error, log: recordingLog, "explicit device start failed for %{public}@, retrying default: %{public}@", normalizedSelection ?? "nil", error.localizedDescription)
            let resolvedDeviceUID = try attemptStartRecording(selectionUID: AudioDevice.systemDefaultSelectionUID)
            DispatchQueue.main.async { self.isRecording = true }
            return RecordingStartResult(usedFallback: true, deviceUID: resolvedDeviceUID)
        }
    }

    /// Duration (in seconds) of the recording up to the last non-silent audio.
    /// Use this to trim trailing silence before uploading.
    var lastNonSilentDuration: TimeInterval {
        tapLock.lock()
        defer { tapLock.unlock() }
        // Add a small buffer (0.3s) to avoid cutting off speech tails
        return lastNonSilentTime > 0 ? lastNonSilentTime + 0.3 : 0
    }

    /// Whether the recording contained enough speech-level audio (not just background noise).
    /// Requires multiple consecutive speech-level buffers to filter out noise spikes.
    var detectedSpeech: Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        return speechBufferCount >= minSpeechBuffers
    }

    /// Time range of detected speech with small padding to preserve natural speech tails.
    /// Returns (start, end) in seconds from recording start, or nil if no speech detected.
    var speechTimeRange: (start: Double, end: Double)? {
        tapLock.lock()
        defer { tapLock.unlock() }
        guard speechBufferCount >= minSpeechBuffers else { return nil }
        let start = max(firstSpeechTime - 0.15, 0)  // small pad before first word
        let end = lastSpeechTime + 0.5               // pad after last word for tails
        return (start, end)
    }

    func stopRecording() -> URL? {
        tapLock.lock()
        let recordedBuffers = bufferCount
        let recordedSpeechBuffers = speechBufferCount
        let lastAudioTime = lastNonSilentTime
        tapLock.unlock()
        os_log(
            .info,
            log: recordingLog,
            "stopRecording() called after %.3fms, buffers=%d, speechBuffers=%d, lastAudio=%.2fs",
            (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000,
            recordedBuffers,
            recordedSpeechBuffers,
            lastAudioTime
        )

        let fileOutput = captureQueue.sync { () -> AVCaptureAudioFileOutput? in
            audioFileOutput
        }
        guard let fileOutput else {
            captureQueue.sync { tearDownCapture(cancelWriter: true) }
            return nil
        }

        let finishedURL: URL?
        if fileOutput.isRecording {
            let semaphore = prepareForFileRecordingWait()
            fileOutput.stopRecording()
            do {
                finishedURL = try finishFileRecordingWait(semaphore)
            } catch {
                os_log(.error, log: recordingLog, "audio file output failed to finish: %{public}@", error.localizedDescription)
                finishedURL = nil
            }
        } else {
            finishedURL = tempFileURL
        }
        captureQueue.sync { tearDownCapture(cancelWriter: false) }

        if finishedURL == nil, let tempFileURL {
            try? FileManager.default.removeItem(at: tempFileURL)
            self.tempFileURL = nil
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }

        tapLock.lock()
        smoothedLevel = 0.0
        tapLock.unlock()
        onRecordingReady = nil

        return finishedURL
    }

    func stopRecordingAsync(completion: @escaping (URL?) -> Void) {
        tapLock.lock()
        let recordedBuffers = bufferCount
        let recordedSpeechBuffers = speechBufferCount
        let lastAudioTime = lastNonSilentTime
        tapLock.unlock()
        os_log(
            .info,
            log: recordingLog,
            "stopRecordingAsync() called after %.3fms, buffers=%d, speechBuffers=%d, lastAudio=%.2fs",
            (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000,
            recordedBuffers,
            recordedSpeechBuffers,
            lastAudioTime
        )

        let finish: (URL?) -> Void = { [weak self] finishedURL in
            guard let self else { return }

            if finishedURL == nil, let tempFileURL = self.tempFileURL {
                try? FileManager.default.removeItem(at: tempFileURL)
                self.tempFileURL = nil
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                completion(finishedURL)
            }

            self.tapLock.lock()
            self.smoothedLevel = 0.0
            self.tapLock.unlock()
            self.onRecordingReady = nil
        }

        let fileOutput = captureQueue.sync { () -> AVCaptureAudioFileOutput? in
            audioFileOutput
        }
        guard let fileOutput else {
            captureQueue.async { [weak self] in
                self?.tearDownCapture(cancelWriter: true)
                finish(nil)
            }
            return
        }

        if fileOutput.isRecording {
            let semaphore = prepareForFileRecordingWait()
            fileOutput.stopRecording()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let finishedURL: URL?
                do {
                    finishedURL = try self.finishFileRecordingWait(semaphore)
                } catch {
                    os_log(.error, log: recordingLog, "audio file output failed to finish: %{public}@", error.localizedDescription)
                    finishedURL = nil
                }
                self.captureQueue.sync { self.tearDownCapture(cancelWriter: false) }
                finish(finishedURL)
            }
        } else {
            let finishedURL = tempFileURL
            captureQueue.async { [weak self] in
                self?.tearDownCapture(cancelWriter: false)
                finish(finishedURL)
            }
        }
    }

    private func computeAudioLevel(rms: Float) {
        let db = 20 * log10f(max(rms, 1e-6))
        let minDb: Float = -50
        let maxDb: Float = -10
        let scaled = max(0, min(1, (db - minDb) / (maxDb - minDb)))

        tapLock.lock()
        if scaled > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.3 + scaled * 0.7
        } else {
            smoothedLevel = smoothedLevel * 0.6 + scaled * 0.4
        }
        let level = smoothedLevel
        tapLock.unlock()

        DispatchQueue.main.async {
            self.audioLevel = level
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

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)

        os_log(.info, log: recordingLog, "preprocessed audio: %{public}@", outputURL.lastPathComponent)
        return outputURL
    }

    /// Whether capture is actively running (for debug UI).
    var isCapturing: Bool {
        captureQueue.sync {
            captureSession?.isRunning ?? false
        }
    }

    /// Forcefully start audio capture to claim the mic.
    func captureAudio(deviceUID: String? = nil) {
        do {
            _ = try startRecording(deviceUID: deviceUID)
            os_log(.info, log: recordingLog, "captureAudio: capture session started")
        } catch {
            os_log(.error, log: recordingLog, "captureAudio failed: %{public}@", error.localizedDescription)
        }
    }

    /// Forcefully tear down capture and release the mic.
    func releaseAudio() {
        _ = stopRecording()
        cleanup()
        os_log(.info, log: recordingLog, "releaseAudio: capture fully torn down")
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processSampleBuffer(sampleBuffer)
    }
}

extension AudioRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        resolveFileRecording(url: outputFileURL, error: error)
    }
}
