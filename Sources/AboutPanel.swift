// AboutPanel.swift — the app menu's About item, and the credits it has to carry
//
// Stage 3 of §9. This is not decoration: the tape saturation kernel is a port of
// Airwindows ToTape6, which is MIT-licensed, and MIT requires "the above copyright
// notice and this permission notice" to be included in all copies or substantial
// portions of the software. A notice that lives only in the repository is not included
// in copies of the app, so the full text is in the panel's credits area — inside the
// binary, reachable from the app menu of every build that ships.
//
// The *standard* panel rather than a custom window, which is a deliberate departure
// from §9's wording. This panel is what macOS and the HIG mean by "About": it brings
// the icon, the name, `CFBundleShortVersionString (CFBundleVersion)` and the
// copyright, sizes itself, and cannot get its layout wrong. A bespoke SwiftUI window
// would re-implement all of that for no visible gain and add one more surface that no
// gate in §9.4 can check — which §9.4 now says in as many words.
//
// The licence text below is the same text as `CREDITS.md` at the repository root: one
// copy has to be in the binary, the other in the repository where a reader looks for
// it. If either changes, change both.

#if os(macOS)
import AppKit
import Foundation

enum AboutPanel {

    /// Where the tape saturation kernel comes from, and its notice — quoted from the
    /// Airwindows repository's own `LICENSE` file rather than paraphrased, because the
    /// wording *is* the licence.
    private static let attribution = """
    Tape Saturation ported from Airwindows ToTape6.
    Copyright (c) 2018 Chris Johnson. MIT licence.
    """

    private static let licence = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of \
    this software and associated documentation files (the "Software"), to deal in the \
    Software without restriction, including without limitation the rights to use, copy, \
    modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, \
    and to permit persons to whom the Software is furnished to do so, subject to the \
    following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, \
    INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A \
    PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT \
    HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE \
    OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    EQ, reverb and delay are Apple's AVAudioUnitEQ, AVAudioUnitReverb and \
    AVAudioUnitDelay. Every other effect kernel is original to TAPE 08.
    """

    /// Shows the panel. Called from `Tape08Commands`, which replaces the stock
    /// `.appInfo` group so this is what the app menu's About item does.
    static func show() {
        let info = Bundle.main.infoDictionary
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            // Fixed rather than read from `CFBundleName`, which the two build paths
            // spell differently ("TAPE 08" in `package.sh`, "Tape 08" in the Xcode
            // plist). The brand is the shouting one, and Stage 5 reconciles the plists.
            .applicationName: "TAPE 08",
            .credits: creditsText(),
        ]
        // The version keys come from the bundle, so bumping the version is a
        // build-setting change and not an edit here. Absent keys are left out rather
        // than passed as empty strings, which would draw a bare "Version ".
        //
        // The copyright line has no option key — the panel reads
        // `NSHumanReadableCopyright` out of the bundle itself, which is why
        // `package.sh`'s generated plist had to gain the key for the dev build's panel
        // to show one at all. It was in the Xcode plist and not there.
        if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            options[.version] = version
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            options[.applicationVersion] = build
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    /// The attribution in full weight, the licence body a point smaller, so the panel
    /// reads as "here is what we used" before it reads as legalese.
    ///
    /// The colour is set explicitly: an attributed string with no colour is drawn black,
    /// which is close to invisible on this panel in Dark Mode. `labelColor` is dynamic
    /// and resolves per appearance.
    private static func creditsText() -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: attribution,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: "\n\n" + licence,
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.labelColor]))
        return text
    }
}
#endif
