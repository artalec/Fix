import Foundation
import SwiftUI
import Combine

/// Выделение треков в списке: одиночное и множественное.
///
/// Логика как в Finder:
///   обычный клик    — выделить только этот трек
///   Cmd+клик        — добавить/убрать трек из выделения
///   Shift+клик      — выделить диапазон от опорного трека до кликнутого
///   Cmd+A           — выделить всё
final class SelectionManager: ObservableObject {

    @Published private(set) var selectedIDs: Set<UUID> = []
    private var anchorID: UUID?

    // MARK: - Запросы

    func isSelected(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    var count: Int { selectedIDs.count }

    var isEmpty: Bool { selectedIDs.isEmpty }

    // MARK: - Изменение выделения

    /// Обычный клик — единственный выделенный трек.
    func selectSingle(_ id: UUID) {
        selectedIDs = [id]
        anchorID = id
    }

    /// Cmd+клик — переключить один трек.
    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchorID = id
    }

    /// Shift+клик — диапазон по порядку списка.
    func selectRange(to id: UUID, in orderedIDs: [UUID]) {
        guard let anchor = anchorID,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let targetIndex = orderedIDs.firstIndex(of: id) else {
            selectSingle(id)
            return
        }
        let range = anchorIndex <= targetIndex
            ? anchorIndex...targetIndex
            : targetIndex...anchorIndex
        selectedIDs = Set(range.map { orderedIDs[$0] })
    }

    func selectAll(_ orderedIDs: [UUID]) {
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
    }

    func clear() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    /// Убрать из выделения то, чего больше нет в списке.
    func prune(keeping orderedIDs: [UUID]) {
        let valid = Set(orderedIDs)
        selectedIDs.formIntersection(valid)
        if let anchor = anchorID, !valid.contains(anchor) {
            anchorID = nil
        }
    }

    /// Выделенные треки в порядке списка.
    func selectedTracks(from tracks: [Track]) -> [Track] {
        tracks.filter { selectedIDs.contains($0.id) }
    }
}
