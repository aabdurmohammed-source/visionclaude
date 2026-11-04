import Foundation
import Combine

/// Modes are disabled: there is only the General mode, no selector bar, no quick actions.
/// The API is kept so the rest of the app (and Settings) still compiles.
@MainActor
class ModeManager: ObservableObject {
    @Published var activeMode: VisionMode = VisionMode.general
    @Published var allModes: [VisionMode] = [VisionMode.general]
    @Published var hiddenBuiltInModeIds: Set<String> = []

    init() {}

    /// Nothing to show in the selector bar.
    var visibleModes: [VisionMode] { [] }

    func addCustomMode(name: String, icon: String, color: String, prompt: String, quickActions: [String]) {}
    func deleteCustomMode(id: String) {}
    func setActiveMode(_ mode: VisionMode) {}
    func toggleBuiltInModeVisibility(id: String) {}
    func isBuiltInModeVisible(_ id: String) -> Bool { false }
}
