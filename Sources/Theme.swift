// Theme.swift — TAPE 08 warm retro palette and shared layout constants
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

import SwiftUI

// ── Theme (warm retro palette) ──────────────────────────────────────────────

enum Theme {
    static let bg            = Color(red: 0x08/255.0, green: 0x08/255.0, blue: 0x0A/255.0)
    static let surface       = Color(red: 0x0C/255.0, green: 0x0C/255.0, blue: 0x0E/255.0)
    static let surfaceRaised = Color(red: 0x1F/255.0, green: 0x1F/255.0, blue: 0x23/255.0)
    static let surfaceInset  = Color(red: 0x08/255.0, green: 0x08/255.0, blue: 0x0A/255.0)
    static let line          = Color(red: 0xEC/255.0, green: 0xE8/255.0, blue: 0xDE/255.0).opacity(0.10)
    static let bezel         = Color(red: 0x2A/255.0, green: 0x28/255.0, blue: 0x24/255.0)

    static let accent        = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)
    static let accentDim     = Color(red: 0x8A/255.0, green: 0x76/255.0, blue: 0x38/255.0)
    static let danger        = Color(red: 0xFF/255.0, green: 0x4D/255.0, blue: 0x5E/255.0)
    static let loopGreen     = Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0)

    static let textPrimary   = Color(red: 0xEC/255.0, green: 0xE8/255.0, blue: 0xDE/255.0)
    static let textSecondary = Color(red: 0x8C/255.0, green: 0x89/255.0, blue: 0x81/255.0)
    static let textTertiary  = Color(red: 0x6E/255.0, green: 0x6B/255.0, blue: 0x64/255.0)
    static let textEngraved  = Color(red: 0x6E/255.0, green: 0x6B/255.0, blue: 0x64/255.0)

    static let eqColor       = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)
    static let reverbColor   = Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0)
    static let delayColor    = Color(red: 0x6F/255.0, green: 0x8C/255.0, blue: 0xFF/255.0)
    static let tapeColor     = Color(red: 0xFF/255.0, green: 0x8A/255.0, blue: 0x3D/255.0)
    static let gold          = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)

    static let waveformCount = 200
    static let trackCount    = 8
    static let clipPeaks     = 64

    /// Inspector drawer widths. The two drawers share one slot to the left of the tape
    /// and the workspace is pushed right by whichever is open, so these are shared layout
    /// constants rather than each panel's private business: the panel's own frame and the
    /// inset that clears it are the same number, and must stay that way.
    static let effectsDrawerWidth:  CGFloat = 400
    static let settingsDrawerWidth: CGFloat = 260

    static let trackColors: [Color] = [
        Color(red: 0xFF/255.0, green: 0x5A/255.0, blue: 0x6A/255.0),
        Color(red: 0x6F/255.0, green: 0x8C/255.0, blue: 0xFF/255.0),
        Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0),
        Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0),
        Color(red: 0xA9/255.0, green: 0x8B/255.0, blue: 0xFF/255.0),
        Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0),
        Color(red: 0xFF/255.0, green: 0x8A/255.0, blue: 0x3D/255.0),
        Color(red: 0xCF/255.0, green: 0xC8/255.0, blue: 0xB8/255.0),
    ]
    static func trackColor(_ i: Int) -> Color { trackColors[i % trackColors.count] }
}
