import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    @Published var isRecording = false

    func startRecording() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create a temp file to write audio to
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        self.tempFileURL = fileURL

        // We'll record in the input's native format, then the file will be a valid WAV
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        self.audioFile = audioFile

        // Convert to mono 16-bit if the input is different
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: monoFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if inputFormat.channelCount == 1 && inputFormat.commonFormat == .pcmFormatFloat32 {
                try? audioFile.write(from: buffer)
            } else if let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * monoFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status != .error {
                    try? audioFile.write(from: convertedBuffer)
                }
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
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
