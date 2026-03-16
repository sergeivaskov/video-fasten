import Foundation
import AVFoundation

public enum ExportError: Error {
    case trackExtractionFailed
    case exportSessionCreationFailed
    case exportFailed(Error?)
    case cancelled
}

public actor ExportEngine {
    private var exportSession: AVAssetExportSession?
    
    public init() {}
    
    public func cancel() {
        exportSession?.cancelExport()
    }
    
    public func export(
        inputURL: URL,
        outputURL: URL,
        speedFactor: Double,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        
        // Load duration
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        
        // Create composition
        let composition = AVMutableComposition()
        
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.trackExtractionFailed
        }
        
        // Load source tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        
        guard let sourceVideoTrack = videoTracks.first,
              let sourceAudioTrack = audioTracks.first else {
            throw ExportError.trackExtractionFailed
        }
        
        // Insert tracks
        try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        try compAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        
        // Scale time
        let newDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speedFactor)
        compVideoTrack.scaleTimeRange(timeRange, toDuration: newDuration)
        compAudioTrack.scaleTimeRange(timeRange, toDuration: newDuration)
        
        // Copy transform to preserve video orientation
        if let transform = try? await sourceVideoTrack.load(.preferredTransform) {
            compVideoTrack.preferredTransform = transform
        }
        
        // Set up audio mix to preserve pitch
        let audioMix = AVMutableAudioMix()
        let audioMixInputParameters = AVMutableAudioMixInputParameters(track: compAudioTrack)
        audioMixInputParameters.audioTimePitchAlgorithm = .timeDomain
        audioMix.inputParameters = [audioMixInputParameters]
        
        // Create export session
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.exportSessionCreationFailed
        }
        
        self.exportSession = session
        
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.audioMix = audioMix
        
        // Progress reporting task
        let progressTask = Task {
            while !Task.isCancelled {
                let status = session.status
                if status == .waiting || status == .exporting {
                    let progress = Double(session.progress)
                    // AVAssetExportSession может долго висеть на 0.0 в начале
                    // Передаем прогресс, чтобы UI мог обновиться
                    progressHandler(progress)
                } else if status == .completed || status == .failed || status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }
        
        // Start export
        await session.export()
        progressTask.cancel()
        
        switch session.status {
        case .completed:
            progressHandler(1.0)
        case .cancelled:
            throw ExportError.cancelled
        case .failed:
            throw ExportError.exportFailed(session.error)
        default:
            throw ExportError.exportFailed(nil)
        }
    }
}
