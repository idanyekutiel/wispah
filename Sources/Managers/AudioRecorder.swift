import Accelerate
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

/// Records microphone audio to a single, continuous canonical-format file.
///
/// Design (see the Phase 2 refactor): the capture delegate does the minimum possible
/// work and hands each buffer to a dedicated serial processing queue. All file I/O,
/// format conversion, RMS metering, and speech detection run there — never on the
/// capture delivery queue — so a slow disk or a heavy meter can't stall capture and
/// cause the silent gaps/corruption Apple warns about (TN2445). Every buffer's format
/// is validated and converted to one canonical format, and timestamp gaps are detected
/// and padded so the written duration stays honest.
final class AudioRecorder: NSObject, ObservableObject {
    /// Queue the capture system delivers sample buffers on. Kept nearly empty.
    private let captureQueue = DispatchQueue(label: "com.idanyekutiel.wispah.capture")
    /// Queue that does the real work (write + convert + meter). Serial → ordered.
    private let processingQueue = DispatchQueue(label: "com.idanyekutiel.wispah.processing")

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioDeviceInput: AVCaptureDeviceInput?

    private var recordingFile: AVAudioFile?
    private var recordingFormat: AVAudioFormat?
    private var tempFileURL: URL?
    private var currentDeviceUID: String?

    /// Cached converter for the (rare) case where incoming buffers don't already
    /// match the canonical format. Keyed by the input format's settings.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    // Timing / gap tracking (processing queue only)
    private var firstSampleTimestamp: CMTime?
    private var expectedNextPTS: CMTime?
    private var writtenFrameCount: AVAudioFramePosition = 0

    private var runtimeErrorObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?

    private let startupLock = NSLock()
    private let lifecycleLock = NSLock()
    private var startupError: Error?
    private var startupResolved = false
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var recordingStartTime: CFAbsoluteTime = 0
    private var suppressRecordingErrors = false

    // MARK: - Thread-safe audio analysis state

    /// Lock protecting mutable audio analysis state shared with the main thread.
    private let tapLock = NSLock()
    private var bufferCount: Int = 0
    private var speechBufferCount: Int = 0
    private var quietSpeechBufferCount: Int = 0
    private var readyFired = false
    private var firstSpeechTime: TimeInterval = 0
    private var lastSpeechTime: TimeInterval = 0
    private var lastNonSilentTime: TimeInterval = 0
    private var peakRMS: Float = 0.0
    private var smoothedLevel: Float = 0.0

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    /// Quiet microphones and a low macOS input-volume setting can put real speech well
    /// below the old 0.005/0.015 cutoffs. Keep a conservative low-level path so a valid
    /// recording is not silently discarded before Whisper gets a chance to inspect it.
    private let quietSpeechThresholdRMS: Float = 0.0008
    private let speechThresholdRMS: Float = 0.015
    /// A few strong buffers are enough; quiet audio must be sustained to reject clicks.
    private let minSpeechBuffers: Int = 4
    private let minQuietSpeechBuffers: Int = 12
    private let startupTimeout: TimeInterval = 2.0
    /// Timestamp gaps larger than this are padded with silence to keep duration honest.
    private let gapDetectionThresholdSeconds: Double = 0.08
    /// Never pad more than this much silence for a single gap (guards against a runaway).
    private let maximumGapPaddingSeconds: Double = 3.0

    /// Called once capture is alive and a real audio buffer has been written.
    var onRecordingReady: (() -> Void)?

    /// Called when a mid-recording error occurs (for example, capture device disconnect).
    /// The error message is passed as the parameter.
    var onRecordingError: ((String) -> Void)?

    // MARK: - Reset audio state

    private func resetTapState() {
        tapLock.lock()
        defer { tapLock.unlock() }
        bufferCount = 0
        speechBufferCount = 0
        quietSpeechBufferCount = 0
        readyFired = false
        firstSpeechTime = 0
        lastSpeechTime = 0
        lastNonSilentTime = 0
        peakRMS = 0.0
        smoothedLevel = 0.0
    }

    // MARK: - Startup synchronization

    private func prepareForStartupMonitoring() {
        startupLock.lock()
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        startupError = nil
        startupResolved = false
        startupLock.unlock()
    }

    private func resolveStartup(error: Error?) {
        startupLock.lock()
        guard !startupResolved else {
            startupLock.unlock()
            return
        }
        startupResolved = true
        startupError = error
        let timeoutWorkItem = startupTimeoutWorkItem
        startupTimeoutWorkItem = nil
        startupLock.unlock()
        timeoutWorkItem?.cancel()
    }

    private func armStartupWatchdog() {
        startupLock.lock()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startupLock.lock()
            let shouldTimeout = !self.startupResolved
            self.startupLock.unlock()
            guard shouldTimeout else { return }
            self.handleCaptureFailure(AudioRecorderError.startupTimedOut)
        }
        startupTimeoutWorkItem = workItem
        startupLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + startupTimeout, execute: workItem)
    }

    private func setSuppressRecordingErrors(_ suppress: Bool) {
        lifecycleLock.lock()
        suppressRecordingErrors = suppress
        lifecycleLock.unlock()
    }

    private func shouldSuppressRecordingErrors() -> Bool {
        lifecycleLock.lock()
        let suppress = suppressRecordingErrors
        lifecycleLock.unlock()
        return suppress
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

    /// Stop the session and detach the delegate. Must run on `captureQueue`.
    private func tearDownSession() {
        removeObservers()
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
            os_log(.info, log: recordingLog, "capture session stopped")
        }
        captureSession = nil
        audioOutput = nil
        audioDeviceInput = nil
        currentDeviceUID = nil
    }

    /// Close the recording file and reset processing state. Must run on `processingQueue`.
    private func finalizeRecordingFile() -> (url: URL?, frames: AVAudioFramePosition) {
        let frames = writtenFrameCount
        recordingFile = nil
        let url = tempFileURL
        converter = nil
        converterInputFormat = nil
        firstSampleTimestamp = nil
        expectedNextPTS = nil
        return (url, frames)
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

        if isRecording && !shouldSuppressRecordingErrors() {
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingError?(error.localizedDescription)
            }
        }
    }

    private func prepareOutputURL() throws -> URL {
        if let existingURL = tempFileURL {
            try? FileManager.default.removeItem(at: existingURL)
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        tempFileURL = fileURL
        return fileURL
    }

    /// Canonical recording format: 16kHz mono 16-bit signed PCM. 16kHz is Whisper's
    /// native rate (and what we upload anyway), so capturing here is lossless for
    /// transcription while cutting data volume, file size, and the pre-upload resample.
    /// Every written buffer is converted to this so the file is uniform regardless of
    /// device quirks.
    private func makeCanonicalFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.invalidInputFormat("Could not create recording format")
        }
        return format
    }

    private func createRecordingFile(at outputURL: URL) throws {
        let format = try makeCanonicalFormat()
        recordingFormat = format
        tempFileURL = outputURL
        recordingFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        writtenFrameCount = 0
        firstSampleTimestamp = nil
        expectedNextPTS = nil
        converter = nil
        converterInputFormat = nil
    }

    private func normalizedCaptureAudioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
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

        session.commitConfiguration()

        try createRecordingFile(at: outputURL)
        captureSession = session
        audioDeviceInput = input
        audioOutput = output
        currentDeviceUID = device.uniqueID

        registerObservers(for: session, deviceUID: device.uniqueID)
        session.startRunning()

        guard session.isRunning else {
            throw AudioRecorderError.captureSessionError("Capture session failed to start")
        }
        os_log(.info, log: recordingLog, "capture session started for %{public}@", device.uniqueID)
    }

    // MARK: - Sample processing (processing queue)

    private func elapsedSeconds(for pts: CMTime) -> TimeInterval {
        guard let firstSampleTimestamp else { return 0 }
        let elapsed = CMTimeSubtract(pts, firstSampleTimestamp)
        return max(CMTimeGetSeconds(elapsed), 0)
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
    }

    /// Produce a canonical-format PCM buffer from an incoming sample buffer, converting
    /// if the device delivered a different format (defends against the documented
    /// mid-stream ASBD changes that otherwise corrupt the file).
    private func canonicalBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let canonical = recordingFormat else {
            throw AudioRecorderError.captureSessionError("Recording format is not available")
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioRecorderError.invalidInputFormat("Sample buffer has no format description")
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("Sample buffer contained no audio frames")
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            throw AudioRecorderError.invalidInputFormat("Could not allocate input buffer")
        }
        inputBuffer.frameLength = inputBuffer.frameCapacity
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioRecorderError.invalidInputFormat("Could not copy audio samples (\(copyStatus))")
        }

        if formatsMatch(inputFormat, canonical) {
            return inputBuffer
        }

        // Convert to canonical via a cached converter.
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: canonical)
            converterInputFormat = inputFormat
            os_log(.info, log: recordingLog, "input format %{public}@ differs from canonical — converting", inputFormat)
        }
        guard let converter else {
            throw AudioRecorderError.invalidInputFormat("Could not create audio converter")
        }

        let ratio = canonical.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sampleCount) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outputCapacity) else {
            throw AudioRecorderError.invalidInputFormat("Could not allocate converted buffer")
        }

        var conversionError: NSError?
        var providedInput = false
        let statusValue = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            throw AudioRecorderError.invalidInputFormat("Audio conversion failed: \(conversionError.localizedDescription)")
        }
        guard statusValue != .error, outputBuffer.frameLength > 0 else {
            throw AudioRecorderError.invalidInputFormat("Audio conversion produced no frames")
        }
        return outputBuffer
    }

    /// Detect a timestamp discontinuity and pad with silence so the written duration
    /// keeps matching wall-clock time (so trimming and coverage checks stay correct).
    private func padSilenceForGapIfNeeded(pts: CMTime) {
        guard let canonical = recordingFormat, let expectedNextPTS else { return }
        let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, expectedNextPTS))
        guard gapSeconds > gapDetectionThresholdSeconds else { return }

        let cappedGap = min(gapSeconds, maximumGapPaddingSeconds)
        os_log(.error, log: recordingLog, "capture gap of %.3fs detected — padding %.3fs of silence", gapSeconds, cappedGap)
        let frames = AVAudioFrameCount(cappedGap * canonical.sampleRate)
        guard frames > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: frames),
              let channel = silence.int16ChannelData else { return }
        silence.frameLength = frames
        memset(channel[0], 0, Int(frames) * MemoryLayout<Int16>.size)
        do {
            try recordingFile?.write(from: silence)
            writtenFrameCount += AVAudioFramePosition(frames)
        } catch {
            os_log(.error, log: recordingLog, "failed to write silence padding: %{public}@", error.localizedDescription)
        }
    }

    /// vDSP-vectorized RMS over a canonical (Int16) buffer, normalized to ~[0, 1).
    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var floats = [Float](repeating: 0, count: count)
        vDSP_vflt16(channel[0], 1, &floats, 1, vDSP_Length(count))
        var rmsValue: Float = 0
        vDSP_rmsqv(floats, 1, &rmsValue, vDSP_Length(count))
        return rmsValue / Float(Int16.max)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSampleTimestamp == nil {
            firstSampleTimestamp = pts
        }

        // Buffer-level problems skip the buffer and keep recording — the next buffer's
        // gap detection pads the seam. Only the session-level observers (runtime error /
        // device disconnect) abort a recording.
        let pcmBuffer: AVAudioPCMBuffer
        do {
            pcmBuffer = try canonicalBuffer(from: sampleBuffer)
        } catch {
            os_log(.error, log: recordingLog, "skipping unprocessable buffer: %{public}@", error.localizedDescription)
            return
        }

        padSilenceForGapIfNeeded(pts: pts)

        guard let canonical = recordingFormat else { return }
        do {
            try recordingFile?.write(from: pcmBuffer)
            writtenFrameCount += AVAudioFramePosition(pcmBuffer.frameLength)
        } catch {
            os_log(.error, log: recordingLog, "skipping buffer after write error: %{public}@", error.localizedDescription)
            return
        }

        // Advance the expected-next timestamp from the buffer's own duration so we track
        // the true capture clock (reconstructing it from frame count re-quantizes each
        // step and the rounding error accumulates into spurious gap padding).
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        if sampleDuration.isValid && sampleDuration.value > 0 {
            expectedNextPTS = CMTimeAdd(pts, sampleDuration)
        } else {
            let bufferSeconds = Double(pcmBuffer.frameLength) / canonical.sampleRate
            expectedNextPTS = CMTimeAdd(pts, CMTimeMakeWithSeconds(bufferSeconds, preferredTimescale: 48_000))
        }

        let rmsValue = rms(of: pcmBuffer)
        let elapsed = elapsedSeconds(for: pts)
        updateAnalysis(rms: rmsValue, elapsed: elapsed)
    }

    private func updateAnalysis(rms rmsValue: Float, elapsed: TimeInterval) {
        var shouldFireReady = false
        var currentBufferCount = 0

        tapLock.lock()
        bufferCount += 1
        currentBufferCount = bufferCount
        peakRMS = max(peakRMS, rmsValue)
        if rmsValue > quietSpeechThresholdRMS {
            quietSpeechBufferCount += 1
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
            os_log(.info, log: recordingLog, "first audio buffer written to disk — recording ready")
            onRecordingReady?()
        }

        computeAudioLevel(rms: rmsValue)
    }

    private func resolveCaptureDevice(for selectionUID: String?) -> AVCaptureDevice? {
        AudioDevice.captureDevice(forSelectionUID: selectionUID)
    }

    private func attemptStartRecording(selectionUID: String?) throws -> String? {
        resetTapState()

        guard let captureDevice = resolveCaptureDevice(for: selectionUID) else {
            throw AudioRecorderError.missingInputDevice
        }

        let outputURL = try prepareOutputURL()
        prepareForStartupMonitoring()

        do {
            try captureQueue.sync {
                tearDownSession()
                try buildCaptureSession(for: captureDevice, outputURL: outputURL)
            }
        } catch {
            resolveStartup(error: error)
            captureQueue.sync { tearDownSession() }
            processingQueue.sync { _ = finalizeRecordingFile() }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        armStartupWatchdog()

        return captureDevice.uniqueID
    }

    // MARK: - Start / Stop recording

    func startRecording(deviceUID: String? = nil) throws -> RecordingStartResult {
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        setSuppressRecordingErrors(false)
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
        return lastNonSilentTime > 0 ? lastNonSilentTime + 0.3 : 0
    }

    /// Whether the recording contained enough speech-level audio (not just background noise).
    var detectedSpeech: Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        return speechBufferCount >= minSpeechBuffers
            || quietSpeechBufferCount >= minQuietSpeechBuffers
    }

    var writtenDuration: TimeInterval {
        guard let recordingFormat else { return 0 }
        // Plain read of an Int64 counter — an estimate sampled in the stop flow. Reading
        // without hopping onto processingQueue avoids stalling the caller (UI) thread on a
        // busy queue; a slightly stale value is fine for the severe-mismatch sanity check.
        return Double(writtenFrameCount) / recordingFormat.sampleRate
    }

    var wallClockDuration: TimeInterval {
        max(CFAbsoluteTimeGetCurrent() - recordingStartTime, 0)
    }

    func stopRecording() -> URL? {
        setSuppressRecordingErrors(true)
        logStopSnapshot(label: "stopRecording")

        captureQueue.sync { tearDownSession() }
        let finished = processingQueue.sync { () -> URL? in
            let result = finalizeRecordingFile()
            return result.frames > 0 ? result.url : nil
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }
        tapLock.lock()
        smoothedLevel = 0.0
        tapLock.unlock()
        onRecordingReady = nil

        return finished
    }

    func stopRecordingAsync(completion: @escaping (URL?) -> Void) {
        setSuppressRecordingErrors(true)
        logStopSnapshot(label: "stopRecordingAsync")

        captureQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.tearDownSession()
            self.processingQueue.async {
                let result = self.finalizeRecordingFile()
                let finished = result.frames > 0 ? result.url : nil
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.audioLevel = 0.0
                    completion(finished)
                }
                self.tapLock.lock()
                self.smoothedLevel = 0.0
                self.tapLock.unlock()
                self.onRecordingReady = nil
            }
        }
    }

    private func logStopSnapshot(label: String) {
        tapLock.lock()
        let recordedBuffers = bufferCount
        let recordedSpeechBuffers = speechBufferCount
        let recordedQuietSpeechBuffers = quietSpeechBufferCount
        let lastAudioTime = lastNonSilentTime
        let recordedPeakRMS = peakRMS
        tapLock.unlock()
        os_log(
            .info,
            log: recordingLog,
            "%{public}@() after %.3fms, buffers=%d, speechBuffers=%d, quietSpeechBuffers=%d, peakRMS=%.6f, lastAudio=%.2fs",
            label,
            (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000,
            recordedBuffers,
            recordedSpeechBuffers,
            recordedQuietSpeechBuffers,
            recordedPeakRMS,
            lastAudioTime
        )
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

        // Don't leave a partial upload file behind if any step below throws.
        var preprocessingSucceeded = false
        defer {
            if !preprocessingSucceeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioRecorderError.invalidInputFormat("No audio track found")
        }

        // Only load the asset duration + set a trim range when trimming is actually
        // requested. The common path passes no trimming, so this skips an asset-duration
        // load on every upload.
        if (trimToSeconds ?? 0) > 0 || skipLeadingSeconds > 0 {
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

        guard reader.startReading() else {
            throw AudioRecorderError.invalidInputFormat("Audio reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // nonisolated(unsafe) silences Sendable warnings — these are only accessed
        // sequentially on the writer's serial queue, so there's no data race.
        nonisolated(unsafe) let writerInputRef = writerInput
        nonisolated(unsafe) let readerOutputRef = readerOutput
        nonisolated(unsafe) let readerRef = reader

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInputRef.requestMediaDataWhenReady(on: DispatchQueue(label: "com.idanyekutiel.wispah.audiopreprocess")) {
                while writerInputRef.isReadyForMoreMediaData {
                    if readerRef.status == .reading, let sampleBuffer = readerOutputRef.copyNextSampleBuffer() {
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
        if reader.status == .failed {
            throw AudioRecorderError.invalidInputFormat("Audio preprocessing read failed: \(reader.error?.localizedDescription ?? "unknown")")
        }

        // Sanity-check the output isn't empty/truncated before handing it off.
        let outputDuration = CMTimeGetSeconds(try await AVURLAsset(url: outputURL).load(.duration))
        guard outputDuration.isFinite, outputDuration > 0 else {
            throw AudioRecorderError.invalidInputFormat("Audio preprocessing produced an empty file")
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        os_log(.info, log: recordingLog, "preprocessed audio: %{public}@ (%.2fs)", outputURL.lastPathComponent, outputDuration)
        preprocessingSucceeded = true
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
        setSuppressRecordingErrors(false)
        captureQueue.sync { tearDownSession() }
        // Session is stopped and the queue drained, so resetting recording state inside
        // the same processingQueue hop keeps all of it confined to one queue (no races
        // with an in-flight process()).
        let urlToRemove: URL? = processingQueue.sync {
            _ = finalizeRecordingFile()
            let url = tempFileURL
            tempFileURL = nil
            recordingFormat = nil
            writtenFrameCount = 0
            return url
        }
        if let urlToRemove {
            try? FileManager.default.removeItem(at: urlToRemove)
        }
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Hand off immediately — all real work happens on the processing queue so a
        // slow write or meter can never stall capture and drop buffers.
        processingQueue.async { [weak self] in
            self?.process(sampleBuffer)
        }
    }
}
