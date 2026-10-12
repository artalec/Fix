import SwiftUI
import AppKit

// MARK: - Application entry point
// ВАЖНО: файл намеренно НЕ называется main.swift. Если положить @main
// в файл с именем main.swift, компилятор трактует модуль как содержащий
// top-level код и падает с ошибкой
// "'main' attribute cannot be used in a module that contains top-level code".

@main
struct DJPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("DJPlayer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Воспроизведение") {
                Button("Воспроизвести / пауза") {
                    AppModel.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Остановить") {
                    AppModel.shared.audioEngine.stop()
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Предыдущий трек") {
                    AppModel.shared.playPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Следующий трек") {
                    AppModel.shared.playNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button("Зациклить трек") {
                    AppModel.shared.updateSettings {
                        $0.loopTrackEnabled.toggle()
                    }
                }

                Button("Зациклить плейлист") {
                    let current = AppModel.shared.selectedPlaylist?.loopEnabled ?? false
                    AppModel.shared.setLoopPlaylist(!current)
                }

                Button("Автопереход к следующему") {
                    let current = AppModel.shared.selectedPlaylist?.autoplayEnabled ?? false
                    AppModel.shared.setAutoplay(!current)
                }
            }

            CommandMenu("Выделение") {
                Button("Выделить все треки") {
                    let orderedIDs = AppModel.shared.selectedPlaylist?.tracks.map(\.id) ?? []
                    AppModel.shared.selection.selectAll(orderedIDs)
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Снять выделение") {
                    AppModel.shared.selection.clear()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Удалить выделенные треки") {
                    AppModel.shared.removeSelectedTracks()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(AppModel.shared.selection.isEmpty)
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Глобальный перехват клавиш на уровне окна (работает и в macOS 13,
        // в отличие от SwiftUI .onKeyPress, который появился только в macOS 14).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Не перехватываем ввод в текстовых полях
            if event.window?.firstResponder is NSTextView { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch event.keyCode {
            case 49: // Space — играть/пауза
                guard flags.isEmpty else { return event }
                AppModel.shared.togglePlayPause()
                return nil

            case 53: // Escape — стоп
                AppModel.shared.audioEngine.stop()
                return nil

            default:
                return event
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.save()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
