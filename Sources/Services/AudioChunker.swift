import AVFoundation
import Foundation
import os.log

/// One extracted segment of a longer recording, plus where it sits on the original
/// timeline. Consecutive chunks overlap by `AudioChunker.Configuration.overlapSeconds`
/// so a word straddling a cut survives in at least one chunk; the overlap is removed
/// when the transcripts are stitched back together.
struct AudioChunk {
    let url: URL
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double { max(endSeconds - startSeconds, 0) }
}

enum AudioChunkerError: LocalizedError {
    case noAudioTrack
    case emptyAsset
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found for chunking"
        case .emptyAsset: return "Audio asset has no usable duration"
        case .readerFailed(let m): return "Chunk reader failed: \(m)"
        case .writerFailed(let m): return "Chunk writer failed: \(m)"
        }
    }
}

/// Splits a long, already-preprocessed (16kHz mono) recording into smaller overlapping
/// files cut at silence troughs rather than fixed time offsets.
///
/// Why this exists: Whisper transcribes long audio with an internal sliding window whose
/// output conditions the next window, so a hallucination near one boundary propagates and
/// the result degrades (loops, truncation) the longer the take. Transcribing independent
/// chunks — each cut at a natural pause and conditioned only on the vocabulary prompt —
/// severs that chain and lets the chunks run concurrently.
final class AudioChunker {
    struct Configuration {
        /// Preferred chunk length; the actual cut is nudged to the nearest silence.
        var targetChunkSeconds: Double = 45
        /// Hard ceiling — a cut is never placed later than this from the chunk start.
        var maxChunkSeconds: Double = 60
        /// A cut is never placed earlier than this from the chunk start.
        var minChunkSeconds: Double = 20
        /// How much the next chunk reaches back before the cut, so a word spanning the
        /// boundary appears in both chunks and survives stitching.
        var overlapSeconds: Double = 2.0
        /// Half-width of the window (around the target) searched for the quietest point.
        var boundarySearchSeconds: Double = 8.0
        /// A trailing chunk shorter than this is merged into the previous one. Whisper
        /// hallucinates badly on very short clips, so a 2s tail must never go out alone.
        var minTailSeconds: Double = 10.0
        /// RMS-envelope frame size used for silence detection.
        var envelopeFrameSeconds: Double = 0.02

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let sampleRate: Double = 16_000

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Split `inputURL` into overlapping chunk files written next to it. The caller owns
    /// the returned files and must delete them. Returns a single-element array (the whole
    /// file copied through) if the audio is too short to benefit from splitting.
    func split(_ inputURL: URL) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioChunkerError.noAudioTrack
        }
        let totalSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw AudioChunkerError.emptyAsset
        }

        let envelope = try readRMSEnvelope(track: track, in: asset)
        let cutTimes = computeCutTimes(totalSeconds: totalSeconds, envelope: envelope)

        // Turn interior cut points into overlapping [start, end] ranges.
        var ranges: [(start: Double, end: Double)] = []
        var rangeStart = 0.0
        for cut in cutTimes {
            ranges.append((rangeStart, cut))
            rangeStart = max(0, cut - configuration.overlapSeconds)
        }
        ranges.append((rangeStart, totalSeconds))

        // A tiny trailing chunk hallucinates — fold it back into the previous chunk
        // (which then slightly exceeds the max length, still far under any provider limit).
        if ranges.count >= 2, let last = ranges.last, (last.end - last.start) < configuration.minTailSeconds {
            let previous = ranges[ranges.count - 2]
            ranges[ranges.count - 2] = (previous.start, last.end)
            ranges.removeLast()
        }

        os_log(.info, log: recordingLog, "chunker: %.1fs split into %d chunks at cuts %{public}@",
               totalSeconds, ranges.count, cutTimes.map { String(format: "%.1f", $0) }.joined(separator: ","))

        var chunks: [AudioChunk] = []
        for (index, range) in ranges.enumerated() {
            do {
                let url = try await extractRange(from: inputURL, start: range.start, end: range.end, index: index)
                chunks.append(AudioChunk(url: url, startSeconds: range.start, endSeconds: range.end))
            } catch {
                // A failed extraction invalidates the split — clean up and let the caller
                // fall back to single-shot transcription of the whole file.
                for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
                throw error
            }
        }
        return chunks
    }

    // MARK: - Cut-point selection

    /// Choose interior cut times (exclusive of 0 and total). Each cut targets
    /// `targetChunkSeconds` past the previous one and is snapped to the quietest frame in
    /// the surrounding search window, clamped to [min, max] chunk length.
    private func computeCutTimes(totalSeconds: Double, envelope: [Float]) -> [Double] {
        var cuts: [Double] = []
        var chunkStart = 0.0

        // Loop while the remaining tail would still exceed one max-length chunk.
        while totalSeconds - chunkStart > configuration.maxChunkSeconds {
            let target = chunkStart + configuration.targetChunkSeconds
            let lo = max(chunkStart + configuration.minChunkSeconds, target - configuration.boundarySearchSeconds)
            let hi = min(chunkStart + configuration.maxChunkSeconds, target + configuration.boundarySearchSeconds, totalSeconds)
            guard hi > lo else { break }

            let cut = quietestTime(in: envelope, from: lo, to: hi) ?? hi
            // Guard against a degenerate cut that wouldn't advance past the overlap.
            guard cut > chunkStart + configuration.overlapSeconds else {
                cuts.append(hi)
                chunkStart = hi
                continue
            }
            cuts.append(cut)
            chunkStart = cut
        }
        return cuts
    }

    /// Time (seconds) of the lowest-RMS envelope frame whose center falls in [from, to],
    /// or nil if the window has no frames.
    private func quietestTime(in envelope: [Float], from: Double, to: Double) -> Double? {
        guard !envelope.isEmpty else { return nil }
        let frame = configuration.envelopeFrameSeconds
        let startIndex = max(0, Int(from / frame))
        let endIndex = min(envelope.count - 1, Int(to / frame))
        guard startIndex <= endIndex else { return nil }

        var bestIndex = startIndex
        var bestValue = Float.greatestFiniteMagnitude
        for index in startIndex...endIndex where envelope[index] < bestValue {
            bestValue = envelope[index]
            bestIndex = index
        }
        return (Double(bestIndex) + 0.5) * frame
    }

    // MARK: - RMS envelope (analysis pass)

    /// Stream the track as 16kHz mono PCM and emit one RMS value per envelope frame.
    private func readRMSEnvelope(track: AVAssetTrack, in asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmReaderSettings())
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioChunkerError.readerFailed("cannot add envelope output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioChunkerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let samplesPerFrame = max(1, Int(sampleRate * configuration.envelopeFrameSeconds))
        var envelope: [Float] = []
        var sumSquares: Float = 0
        var frameSampleCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let dataPointer, length >= 2 else { continue }

            let sampleCount = length / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    let value = Float(samples[i]) / Float(Int16.max)
                    sumSquares += value * value
                    frameSampleCount += 1
                    if frameSampleCount >= samplesPerFrame {
                        envelope.append((sumSquares / Float(frameSampleCount)).squareRoot())
                        sumSquares = 0
                        frameSampleCount = 0
                    }
                }
            }
        }
        if frameSampleCount > 0 {
            envelope.append((sumSquares / Float(frameSampleCount)).squareRoot())
        }

        if reader.status == .failed {
            throw AudioChunkerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        return envelope
    }

    // MARK: - Range extraction (write pass)

    /// Decode [start, end] of the source and re-encode it to a standalone 16kHz mono AAC
    /// file. `startSession(atSourceTime:)` is pinned to the range start so the output is
    /// re-based to zero (no leading silence from the original timeline offset).
    private func extractRange(from inputURL: URL, start: Double, end: Double, index: Int) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioChunkerError.noAudioTrack
        }
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("chunk_\(index)_\(UUID().uuidString).m4a")

        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: outputURL) }
        }

        let reader = try AVAssetReader(asset: asset)
        let startTime = CMTime(seconds: start, preferredTimescale: 16_000)
        let endTime = CMTime(seconds: end, preferredTimescale: 16_000)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmReaderSettings())
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioChunkerError.readerFailed("cannot add chunk output")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacWriterSettings())
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioChunkerError.writerFailed("cannot add chunk input")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioChunkerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        writer.startWriting()
        writer.startSession(atSourceTime: startTime)

        // nonisolated(unsafe): accessed only sequentially on the writer's serial queue.
        nonisolated(unsafe) let writerInputRef = writerInput
        nonisolated(unsafe) let readerOutputRef = readerOutput
        nonisolated(unsafe) let readerRef = reader

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInputRef.requestMediaDataWhenReady(on: DispatchQueue(label: "com.idanyekutiel.wispah.chunkextract")) {
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
            throw AudioChunkerError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        if reader.status == .failed {
            throw AudioChunkerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        succeeded = true
        return outputURL
    }

    private func pcmReaderSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func aacWriterSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }
}
