// Theme.swift — colours carried over from OP-XY Monitor, plus one colour per track.

import SwiftUI

public enum Theme {
    public static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    public static let bg            = hex(0x26282B)
    public static let lane          = hex(0x2A2C30)
    public static let surface       = hex(0x2F3236)
    public static let line          = hex(0x3A3D42)
    public static let accent        = hex(0xFF6B1F)
    public static let textPrimary   = hex(0xECEAE6)
    public static let textSecondary = hex(0x8F939A)
    public static let textTertiary  = hex(0x5C6066)
    public static let danger        = hex(0xF2473F)
    public static let cycle         = hex(0xC9B45C)

    public static let trackColors: [Color] = [
        hex(0xFF6B1F), hex(0xC9B45C), hex(0x7FCFB6), hex(0x8C96F7),
        hex(0xE86A9A), hex(0x6DB7E8), hex(0xA7D36B), hex(0xB58CF0),
    ]

    public static func track(_ index: Int) -> Color {
        trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count]
    }

    public static let rulerHeight: CGFloat = 24
    public static let mono = Font.system(size: 10, design: .monospaced)
    public static let label = Font.system(size: 9, weight: .bold, design: .monospaced)
}
