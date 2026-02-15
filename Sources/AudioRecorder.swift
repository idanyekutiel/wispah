import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0

    func startRecording() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create a temp file to write audio to
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        self.tempFileURL = fileURL

        // Record as AAC at 16kHz mono (Whisper operates at 16kHz internally)
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        self.audioFile = audioFile

        // Convert input to mono 16kHz float32 for writing to AAC file
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: monoFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let converter = converter else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * monoFormat.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status != .error {
                try? audioFile.write(from: convertedBuffer)
                self?.computeAudioLevel(from: convertedBuffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        self.audioEngine = audioEngine
        self.isRecording = true
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }
        return tempFileURL
    }

    private func computeAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let samples = channelData[0]
        var sumOfSquares: Float = 0.0
        for i in 0..<frames {
            let sample = samples[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrtf(sumOfSquares / Float(frames))

        // Scale RMS (~0.01-0.1 for speech) to 0-1 range
        let scaled = min(rms * 10.0, 1.0)

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

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
