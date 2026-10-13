# Fixtures

Test inputs for the checks in `to_fix.md` §8.6 that need a crafted file rather than a live
gesture. Nothing here is a build input — the Xcode target's synchronized group is scoped to
`../Sources`, so this directory cannot end up in the app.

## `make-h6-fixture.sh` — the tampered-manifest fixture (H6)

Builds a `.xyproj` whose `project.json` carries six hostile `relativePath` values, for the
check that manifest paths are resolved **inside** the project package (`ab46dd5`).

```sh
./Fixtures/make-h6-fixture.sh
```

Then in TAPE 08: **Open Project → `Fixtures/build` → `H6-Tampered.xyproj`**.

Expected status line, exactly:

```
Loaded H6-Tampered (1 missing file, 6 paths outside the project)
```

Track 1 must hold one clip; tracks 2 and up must be empty.

### What each case is for

| In the manifest | Why it is there |
|---|---|
| `Audio/Track 1/good.wav` | The control. One clip must load, or the fixture proves nothing. |
| `Audio/Track 1/./good.wav` | A `.` component. Resolves to the *same real file*, so a guard that only checked containment — or only checked components — is caught by the other. |
| `Audio/../Audio/Track 1/good.wav` | A `..` component, same idea the other way round. |
| `Audio/Track 2/gone.wav` | Genuinely absent, so the two failure kinds stay distinguishable: a moved project is not a tampered one. |
| `../H6-target.wav` | Traversal. The target **exists** and is audible — an octave below the good take — so a regression is heard rather than inferred from a count. |
| `/etc/hosts` | Absolute. A real file, so a guard that let it through would read something. |
| `` (empty) | The degenerate case. |
| `Audio/escape.wav` | A symlink inside the package pointing out of it. This is the one a purely lexical check cannot catch — no `.`, no `..`, not absolute — which is why `resolveInPackage` compares resolved paths. |

Every escape case aims at a file that exists. A path pointing at nothing would be refused
whether the guard worked or not, so the fixture would pass either way.

### Regenerating

The script rebuilds `build/` from scratch each run, and `build/` is git-ignored (`*.wav`
already was; `Fixtures/build/` covers the rest). Only the script and this file are tracked.
