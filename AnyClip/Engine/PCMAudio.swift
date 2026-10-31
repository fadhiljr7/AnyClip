//
//  PCMAudio.swift
//  AnyClip
//
//  Decodes the audio of any file AVFoundation can read into 16 kHz mono floats,
//  the form both Whisper and the cut finder work with.
//

import Foundation
import AVFoundation

nonisolated enum PCMAudio {
    static let sampleRate = 16_000.0

    /// Calls `body` with each decoded run of samples and its start time in the file, in order. Nothing happens
    /// for a file without audio. `range` limits decoding to a stretch of the file. Stops when the task is cancelled.
    static func read(media: URL, range: CMTimeRange? = nil,
                     body: ([Float], _ start: Double) throws -> Void) async throws {
        let asset = AVURLAsset(url: media)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        if let range { reader.timeRange = range }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        while let ready = try await provider.next() {
            try Task.checkCancellation()
            let start = ready.presentationTimeStamp.seconds
            let samples = ready.withUnsafeSampleBuffer { floats(in: $0) }
            if !samples.isEmpty { try body(samples, start) }
        }
    }

    private static func floats(in buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }
}
