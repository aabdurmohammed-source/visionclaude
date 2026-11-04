import SwiftUI

/// Single general-purpose mode. The job-specific modes (mechanic, HVAC, plumber, ...) were removed.
struct VisionMode: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let icon: String          // SF Symbol name
    let color: String         // hex color (e.g. "#FF6600")
    let systemPrompt: String
    let quickActions: [String] // suggested voice commands
    let isBuiltIn: Bool

    var swiftColor: Color {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let value = UInt64(hex, radix: 16) else {
            return .orange
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static func == (lhs: VisionMode, rhs: VisionMode) -> Bool {
        lhs.id == rhs.id
    }

    static let general = VisionMode(
        id: "general",
        name: "General",
        icon: "eye.fill",
        color: "#E87B35",
        systemPrompt: "",
        quickActions: [],
        isBuiltIn: true
    )

    static let builtInModes: [VisionMode] = [general]
}
