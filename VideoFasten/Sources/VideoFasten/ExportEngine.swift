import Foundation
import AVFoundation
import CoreMedia

public enum ExportError: Error {
    case trackExtractionFailed
    case readerWriterCreationFailed
    case exportFailed(Error?)
    case cancelled
}

public class ExportEngine {
    private var isCancelled = false
    private let queue = DispatchQueue(label: "com.videofasten.exportEngine")
    
    public init() {}
    
    public func cancel() {
        queue.sync {
            isCancelled = true
        }
    }
    
    private func checkCancelled() -> Bool {
        queue.sync {
            return isCancelled
        }
    }
    
    public func export(
        inputURL: URL,
        outputURL: URL,
        speedFactor: Double,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        isCancelled = false
        
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.trackExtractionFailed
        }
        
        let reader: AVAssetReader
        let writer: AVAssetWriter
        
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ExportError.readerWriterCreationFailed
        }
        
        // Video Setup (Passthrough)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(videoOutput) {
            reader.add(videoOutput)
        }
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try? await videoTrack.load(.formatDescriptions).first)
        videoInput.expectsMediaDataInRealTime = false
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoInput.transform = transform
        }
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }
        
        // Audio Setup (Re-encode with Pitch Preservation)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: audioSettings)
        audioOutput.alwaysCopiesSampleData = false
        
        // Для изменения скорости аудио с сохранением тональности
        // нам недостаточно просто поменять PTS у буферов. Нужно использовать алгоритм time-stretching.
        // AVMutableAudioMix не меняет скорость сам по себе, он только задает алгоритм (timeDomain).
        // Чтобы скорость реально изменилась при чтении, нужно применить scaleTimeRange к самому треку в композиции.
        // Поскольку мы читаем напрямую из asset, нам нужно создать промежуточную композицию.
        
        let composition = AVMutableComposition()
        guard let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.trackExtractionFailed
        }
        
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        
        let newDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speedFactor)
        compAudioTrack.scaleTimeRange(timeRange, toDuration: newDuration)
        
        let compAudioOutput = AVAssetReaderAudioMixOutput(audioTracks: [compAudioTrack], audioSettings: audioSettings)
        compAudioOutput.alwaysCopiesSampleData = false
        
        let audioMix = AVMutableAudioMix()
        let audioMixInputParams = AVMutableAudioMixInputParameters(track: compAudioTrack)
        audioMixInputParams.audioTimePitchAlgorithm = .timeDomain
        audioMix.inputParameters = [audioMixInputParams]
        compAudioOutput.audioMix = audioMix
        
        // Пересоздаем reader с композицией для аудио
        let audioReader: AVAssetReader
        do {
            audioReader = try AVAssetReader(asset: composition)
            if audioReader.canAdd(compAudioOutput) {
                audioReader.add(compAudioOutput)
            }
        } catch {
            throw ExportError.readerWriterCreationFailed
        }
        
        var channelLayout = AudioChannelLayout()
        memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        
        let outputAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
            AVChannelLayoutKey: Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
        
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputAudioSettings)
        audioInput.expectsMediaDataInRealTime = false
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
        
        guard reader.startReading() else {
            let error = reader.error ?? NSError(domain: "AVFoundation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading video"])
            throw ExportError.exportFailed(error)
        }
        
        guard audioReader.startReading() else {
            let error = audioReader.error ?? NSError(domain: "AVFoundation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading audio"])
            throw ExportError.exportFailed(error)
        }
        
        guard writer.startWriting() else {
            let error = writer.error ?? NSError(domain: "AVFoundation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
            throw ExportError.exportFailed(error)
        }
        
        writer.startSession(atSourceTime: .zero)
        
        let videoQueue = DispatchQueue(label: "com.videofasten.videoQueue")
        let audioQueue = DispatchQueue(label: "com.videofasten.audioQueue")
        
        let group = DispatchGroup()
        
        var videoCompleted = false
        var audioCompleted = false
        let completionLock = NSLock()
        
        let totalDurationSeconds = duration.seconds
        var lastVideoProgress: Double = 0
        var lastAudioProgress: Double = 0
        
        let progressQueue = DispatchQueue(label: "com.videofasten.progressQueue")
        
        func updateProgress(video: Double?, audio: Double?) {
            progressQueue.async {
                if let v = video { lastVideoProgress = v }
                if let a = audio { lastAudioProgress = a }
                let progress = (lastVideoProgress + lastAudioProgress) / 2.0
                let clamped = min(max(progress, 0.0), 1.0)
                DispatchQueue.main.async {
                    progressHandler(clamped)
                }
            }
        }
        
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if self.checkCancelled() {
                    videoInput.markAsFinished()
                    completionLock.lock()
                    if !videoCompleted { videoCompleted = true; group.leave() }
                    completionLock.unlock()
                    return
                }
                
                if reader.status != .reading || writer.status != .writing {
                    videoInput.markAsFinished()
                    completionLock.lock()
                    if !videoCompleted { videoCompleted = true; group.leave() }
                    completionLock.unlock()
                    return
                }
                
                if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                    if let adjustedBuffer = self.adjustTime(for: sampleBuffer, speedFactor: speedFactor) {
                        if writer.status == .writing && videoInput.isReadyForMoreMediaData {
                            videoInput.append(adjustedBuffer)
                        }
                        
                        let pts = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)
                        let progress = pts.seconds / (totalDurationSeconds / speedFactor)
                        updateProgress(video: progress, audio: nil)
                    }
                } else {
                    videoInput.markAsFinished()
                    completionLock.lock()
                    if !videoCompleted { videoCompleted = true; group.leave() }
                    completionLock.unlock()
                    break
                }
            }
        }
        
        group.enter()
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if self.checkCancelled() {
                    audioInput.markAsFinished()
                    completionLock.lock()
                    if !audioCompleted { audioCompleted = true; group.leave() }
                    completionLock.unlock()
                    return
                }
                
                if audioReader.status != .reading || writer.status != .writing {
                    audioInput.markAsFinished()
                    completionLock.lock()
                    if !audioCompleted { audioCompleted = true; group.leave() }
                    completionLock.unlock()
                    return
                }
                
                if let sampleBuffer = compAudioOutput.copyNextSampleBuffer() {
                    // Для аудио из композиции нам НЕ НУЖНО пересчитывать таймстемпы вручную,
                    // так как scaleTimeRange уже применен к треку композиции.
                    // Мы просто пишем буфер как есть.
                    if writer.status == .writing && audioInput.isReadyForMoreMediaData {
                        audioInput.append(sampleBuffer)
                    }
                    
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let progress = pts.seconds / (totalDurationSeconds / speedFactor)
                    updateProgress(video: nil, audio: progress)
                } else {
                    audioInput.markAsFinished()
                    completionLock.lock()
                    if !audioCompleted { audioCompleted = true; group.leave() }
                    completionLock.unlock()
                    break
                }
            }
        }
        
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }
        
        if isCancelled {
            reader.cancelReading()
            audioReader.cancelReading()
            writer.cancelWriting()
            throw ExportError.cancelled
        }
        
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.exportFailed(reader.error)
        }
        if audioReader.status == .failed {
            writer.cancelWriting()
            throw ExportError.exportFailed(audioReader.error)
        }
        if writer.status == .failed {
            reader.cancelReading()
            audioReader.cancelReading()
            throw ExportError.exportFailed(writer.error)
        }
        
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        progressHandler(1.0)
    }
    
    nonisolated private func adjustTime(for sampleBuffer: CMSampleBuffer, speedFactor: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        
        guard count > 0 else { return sampleBuffer }
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<Int(count) {
            timingInfo[i].presentationTimeStamp = CMTimeMultiplyByFloat64(timingInfo[i].presentationTimeStamp, multiplier: 1.0 / speedFactor)
            timingInfo[i].duration = CMTimeMultiplyByFloat64(timingInfo[i].duration, multiplier: 1.0 / speedFactor)
            if timingInfo[i].decodeTimeStamp != .invalid {
                timingInfo[i].decodeTimeStamp = CMTimeMultiplyByFloat64(timingInfo[i].decodeTimeStamp, multiplier: 1.0 / speedFactor)
            }
        }
        
        var newSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        
        return newSampleBuffer
    }
}
