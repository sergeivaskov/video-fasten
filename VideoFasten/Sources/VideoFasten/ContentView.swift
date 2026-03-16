import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var coordinator = MediaCoordinator()

    var body: some View {
        VStack(spacing: 20) {
            // Превью видео
            Group {
                if let player = coordinator.player {
                    VideoPlayer(player: player)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            Text("Выберите видео для предпросмотра")
                                .foregroundColor(.secondary)
                        )
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: 500)
            .cornerRadius(8)

            // Управление
            HStack(spacing: 16) {
                Button(action: selectFile) {
                    Text("Выбрать файл...")
                }
                .disabled(coordinator.isExporting)

                Spacer()

                Text("Скорость:")
                
                TextField("Скорость", value: $coordinator.playbackSpeed, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .disabled(coordinator.isExporting)
                
                Text("x")
                
                Slider(value: $coordinator.playbackSpeed, in: 0.5...2.5, step: 0.1)
                    .frame(width: 150)
                    .disabled(coordinator.isExporting)
            }
            .padding(.horizontal)

            // Прогресс и кнопки Старт/Отмена
            HStack {
                if coordinator.isExporting {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: coordinator.exportProgress, total: 1.0)
                            .progressViewStyle(.linear)
                        
                        HStack {
                            Text("\(String(format: "%.2f", coordinator.exportProgress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                            
                            Spacer()
                            
                            Text(coordinator.estimatedTimeRemaining)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    
                    Button("Отмена") {
                        coordinator.cancelExport()
                    }
                    .keyboardShortcut(.cancelAction)
                    .padding(.leading, 8)
                } else {
                    Spacer()
                    Button("Старт") {
                        coordinator.startExport()
                    }
                    .disabled(coordinator.selectedFileURL == nil)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 450)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            coordinator.loadVideo(url: url)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
