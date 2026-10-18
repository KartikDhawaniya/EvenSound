# EvenSound

A macOS app (14.2 or later) that balances the sound of every app. It uses Core Audio process taps,
so no audio driver is needed. There are two balancing styles:

- **Smooth curve** (default): each input level maps to an output level along an arctan curve. Loud
  sound approaches the maximum level, quiet sound approaches the minimum, and sound in the middle is
  barely changed. Flatten sets the slope in the middle.
- **Thresholds**: quiet sound is lifted toward a quiet threshold and loud sound is pulled toward a peak
  threshold. Each slider sets the share of the gap or excess that is corrected.

## Build and test

Requires the Xcode Command Line Tools (Swift 6).

```sh
swift test                  # sound-processing tests
./scripts/build-app.sh      # builds build/EvenSound.app and archives a zip of this version
open build/EvenSound.app
```

On first launch, allow **System Audio Recording** when macOS asks.

## Versions

- The current version number is in `VERSION`. The build script stamps it into the app, together with
  a build number and the git commit. The Settings tab shows them.
- Every build is also saved as `build/versions/EvenSound-<version>-<commit>.zip`. The commit name ends
  in `-modified` if there were uncommitted changes when you built.
- Each release is a git tag (`v0.1.0`, …).

Common tasks:

```sh
git tag                                   # list saved versions
git checkout v0.1.0 && ./scripts/build-app.sh && git checkout main
                                          # rebuild an older version
git switch -c experiment-sliders          # try changes without touching main
```

To release a new version:

```sh
echo 0.2.0 > VERSION
git commit -am "Release 0.2.0"
git tag v0.2.0
./scripts/build-app.sh
```

Only one copy of EvenSound runs at a time. To switch versions, quit the running one first.

## Install on another Mac

Unzip a build, move `EvenSound.app` to `/Applications`, open it, and click **Open Anyway** in
System Settings → Privacy & Security. The app is ad-hoc signed and built for Apple silicon only.
