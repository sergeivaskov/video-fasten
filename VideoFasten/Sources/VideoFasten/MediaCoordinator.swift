import Foundation
import AVFoundation

class MediaCoordinator: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var playbackSpeed: Float = 1.0 {
        didSet {
            updatePlayerRate()
        }
    }
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0.0
    @Published var estimatedTimeRemaining: String = "Вычисление..."
    
    private var exportStartTime: Date?
    private var lastProgressUpdate: Date?

    @Published var player: AVPlayer?

    func loadVideo(url: URL) {
        self.selectedFileURL = url
        
        let playerItem = AVPlayerItem(url: url)
        // Сохранение высоты тона звука (pitch) при изменении скорости
        playerItem.audioTimePitchAlgorithm = .timeDomain
        
        self.player = AVPlayer(playerItem: playerItem)
        updatePlayerRate()
        self.player?.play()
    }

    private func updatePlayerRate() {
        // Если плеер на паузе, мы не должны менять rate, иначе он автоматически начнет воспроизведение.
        // Вместо этого мы устанавливаем defaultRate, который применится при следующем нажатии Play.
        player?.defaultRate = playbackSpeed
        
        // Если видео уже проигрывается (rate > 0), обновляем текущую скорость
        if let player = player, player.rate > 0 {
            player.rate = playbackSpeed
        }
    }

    private var exportEngine: ExportEngine?
    
    func startExport() {
        guard let inputURL = selectedFileURL else { return }
        
        // Ставим плеер на паузу перед экспортом, чтобы освободить ресурсы
        player?.pause()
        
        isExporting = true
        exportProgress = 0.0
        estimatedTimeRemaining = "Подготовка..."
        exportStartTime = Date()
        lastProgressUpdate = Date()
        
        let directory = inputURL.deletingLastPathComponent()
        let filename = inputURL.deletingPathExtension().lastPathComponent
        let extensionStr = inputURL.pathExtension
        let outputURL = directory.appendingPathComponent("\(filename)_\(playbackSpeed)x").appendingPathExtension(extensionStr)
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
            
        exportEngine = ExportEngine()
        
        Task {
            do {
                try await exportEngine?.export(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    speedFactor: Double(playbackSpeed),
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.exportProgress = progress
                            self.updateEstimatedTime(progress: progress)
                        }
                    }
                )
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 1.0
                    self.estimatedTimeRemaining = ""
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.estimatedTimeRemaining = ""
                    print("Export failed: \(error)")
                }
            }
        }
    }
    
    private func updateEstimatedTime(progress: Double) {
        // Если прогресс слишком мал, не пытаемся считать время, чтобы избежать скачков
        guard progress > 0.02, let startTime = exportStartTime else { 
            if progress > 0 {
                estimatedTimeRemaining = "Вычисление..."
            }
            return 
        }
        
        // Ограничиваем частоту обновления текста (не чаще 2 раз в секунду)
        let now = Date()
        if let lastUpdate = lastProgressUpdate, now.timeIntervalSince(lastUpdate) < 0.5 {
            return
        }
        lastProgressUpdate = now
        
        let elapsedTime = now.timeIntervalSince(startTime)
        let totalEstimatedTime = elapsedTime / progress
        let remainingTime = totalEstimatedTime - elapsedTime
        
        if remainingTime < 0 {
            estimatedTimeRemaining = "Завершение..."
            return
        }
        
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        
        if let formattedString = formatter.string(from: remainingTime) {
            estimatedTimeRemaining = "Осталось: \(formattedString)"
        }
    }
    
    func cancelExport() {
        Task {
            await exportEngine?.cancel()
            await MainActor.run {
                self.isExporting = false
                self.exportProgress = 0.0
                self.estimatedTimeRemaining = ""
            }
        }
    }
}
