#!/bin/bash
# make-h6-fixture.sh — builds the tampered-manifest fixture for the H6 check (to_fix.md §8.6).
#
# H6 is "manifest paths are resolved inside the project package". Checking it by hand means
# editing a project.json mid-run and crafting six hostile paths, which is fiddly enough to get
# skipped — and `ab46dd5` is one of the few security-adjacent changes in the tree. This builds
# the whole thing, so the check is "open this, read the status line" instead of "write a
# manifest".
#
# The fixture is generated rather than committed because .gitignore already excludes *.wav, and
# a checked-in package would have to fight that. Run this, then open the package it prints.
#
#   ./Fixtures/make-h6-fixture.sh
#   open "Fixtures/build"        # then select H6-Tampered.xyproj in TAPE 08's Open Project
#
# Expected status line, exactly:
#
#   Loaded H6-Tampered (1 missing file, 6 paths outside the project)
#
# Six refused, one genuinely missing, one real clip loaded. Anything else — a different count,
# a clean "Loaded H6-Tampered" — is the guard failing, and the clip it let through is named in
# the manifest below.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
PKG="$BUILD/H6-Tampered.xyproj"
OUTSIDE="$BUILD/H6-target.wav"     # the file every escape case points at

# Idempotent: the symlink and the package both need to not already exist.
rm -rf "$BUILD"
mkdir -p "$PKG/Audio/Track 1"

# ── Audio ────────────────────────────────────────────────────────────────────────────────
# Both tones are real audio on purpose. A refusal that returns nil is indistinguishable from
# a path pointing at nothing, so every escape case below aims at a file that genuinely exists
# — if the guard ever regresses, the clip loads (and, for the traversal case, is *audible*:
# H6-target is a different pitch from the good take, so a leaked path is heard, not inferred).
python3 - "$PKG/Audio/Track 1/good.wav" "$OUTSIDE" <<'PY'
import math, struct, sys, wave

def write(path, seconds, freq, amp):
    rate = 44100
    n = int(rate * seconds)
    with wave.open(path, "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        buf = bytearray()
        for i in range(n):
            v = int(amp * 32767 * math.sin(2 * math.pi * freq * i / rate))
            buf += struct.pack("<hh", v, v)
        w.writeframes(bytes(buf))

write(sys.argv[1], 0.5, 440.0, 0.25)   # the good take: A4
write(sys.argv[2], 0.5, 220.0, 0.25)   # the escape target: A3, an octave down
PY

# ── The symlink escape ───────────────────────────────────────────────────────────────────
# A symlink *inside* the package whose target is outside it. This is the case a purely lexical
# check cannot catch — the path has no "." or ".." in it and is not absolute — which is why
# resolveInPackage compares the *resolved* paths rather than the components alone.
ln -s "../../H6-target.wav" "$PKG/Audio/escape.wav"

# ── The manifest ─────────────────────────────────────────────────────────────────────────
# Track 0 holds the one clip that must load, plus two paths that resolve to that very same
# file but arrive through a "." or ".." component — so a guard that only stripped components
# would still have to be caught by the containment check, and vice versa.
#
# Track 1 holds the one file that is legitimately missing, plus the four remaining escapes:
# traversal, absolute, empty, symlink.
cat > "$PKG/project.json" <<'JSON'
{
  "version": 1,
  "bpm": 120,
  "metronomeEnabled": true,
  "metronomeVolume": 0.45,
  "quantizeMode": 0,
  "countInBars": 0,
  "loopEnabled": true,
  "masterVolume": 0.3,
  "inputVolume": 0.3,
  "selectedTrack": 0,
  "masterLimiterEnabled": true,
  "effectChain": [],
  "tracks": [
    {
      "index": 0,
      "volume": 0.8,
      "pan": 0,
      "muted": false,
      "solo": false,
      "clips": [
        { "relativePath": "Audio/Track 1/good.wav", "duration": 0.5 },
        { "relativePath": "Audio/Track 1/./good.wav", "duration": 0.5 },
        { "relativePath": "Audio/../Audio/Track 1/good.wav", "duration": 0.5 }
      ]
    },
    {
      "index": 1,
      "volume": 0.8,
      "pan": 0,
      "muted": false,
      "solo": false,
      "clips": [
        { "relativePath": "Audio/Track 2/gone.wav", "duration": 0.5 },
        { "relativePath": "../H6-target.wav", "duration": 0.5 },
        { "relativePath": "/etc/hosts", "duration": 0.5 },
        { "relativePath": "", "duration": 0.5 },
        { "relativePath": "Audio/escape.wav", "duration": 0.5 }
      ]
    }
  ]
}
JSON

echo "Built: $PKG"
echo "       $OUTSIDE   (the escape target — must NOT appear as a clip)"
echo
echo "Open TAPE 08 → Open Project → Fixtures/build → H6-Tampered.xyproj"
echo
echo "Expect, exactly:"
echo "  Loaded H6-Tampered (1 missing file, 6 paths outside the project)"
echo "and track 1 holding one clip (A4). Tracks 2+ must be empty."
