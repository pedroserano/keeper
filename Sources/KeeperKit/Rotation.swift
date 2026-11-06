// A quarter-turn rotation, as ApplePhotosRotator's RotatorCore defines it.

/// A clockwise rotation, in multiples of 90°, applied to a photo as it's currently shown.
public enum Rotation: Int, CaseIterable, Codable, Sendable, Hashable {
    case none = 0
    case clockwise90 = 90
    case rotate180 = 180
    case clockwise270 = 270

    /// Any angle in degrees (clockwise), snapped to the nearest multiple of 90°.
    public init(degrees: Int) {
        let snapped = ((Int((Double(degrees) / 90).rounded()) * 90) % 360 + 360) % 360
        self = Rotation(rawValue: snapped) ?? .none
    }

    public var degrees: Int { rawValue }

    /// The rotation that undoes this one.
    public var inverse: Rotation { Rotation(degrees: 360 - rawValue) }

    /// Applying `self` and then `other`.
    public func followed(by other: Rotation) -> Rotation { Rotation(degrees: rawValue + other.rawValue) }
}

extension Rotation {
    /// Whether this rotation swaps width and height.
    public var swapsDimensions: Bool { self == .clockwise90 || self == .clockwise270 }

    public var label: String {
        switch self {
        case .none: "No rotation"
        case .clockwise90: "Rotate 90° clockwise"
        case .rotate180: "Rotate 180°"
        case .clockwise270: "Rotate 90° counterclockwise"
        }
    }

    /// For badges: "90° ↻", "180°", "90° ↺".
    public var shortLabel: String {
        switch self {
        case .none: "0°"
        case .clockwise90: "90° ↻"
        case .rotate180: "180°"
        case .clockwise270: "90° ↺"
        }
    }

    /// The three rotations that actually change a photo.
    public static let corrections: [Rotation] = [.clockwise90, .rotate180, .clockwise270]
}
