# Homebrew tap

`keystrand.rb` is a Homebrew formula that builds Keystrand from the source
archive of a tagged GitHub Release. It belongs in a personal tap
(`sstawiarski/homebrew-keystrand`). Homebrew's own repositories do not take it:
homebrew/core does not accept a formula whose main product is a macOS
`.app`, and a homebrew/cask entry needs a prebuilt app, which Keystrand does
not publish.

## What the formula does

- Requires macOS 26 and Xcode 26 or later. XcodeGen is a build dependency.
- Runs `xcodegen generate`, then a Release `xcodebuild` for the Mac's own
  architecture. The tag's version becomes `CFBundleShortVersionString` and
  `CFBundleVersion`. A `--HEAD` build reads both from `scripts/version.sh`.
- Turns off the SwiftPM manifest sandbox and the Swift macro sandbox. Both
  call `sandbox-exec`, which fails inside Homebrew's own build sandbox.
- Signs the app ad hoc with the hardened runtime and installs it into the
  keg as `$(brew --prefix)/opt/keystrand/Keystrand.app`.
- `brew test` checks the bundle version and the code signature.

## Formula or cask

A formula builds on the user's Mac, so it needs no prebuilt binary, no
Developer ID certificate, and no notarization. The cost is where the app
ends up. A formula may write only inside its own keg, and `brew linkapps`
no longer exists, so the app stays in the Homebrew prefix. The install
caveat gives two ways to put it in `/Applications`:

- `ln -sfn` makes a link. It keeps pointing at the newest version after
  `brew upgrade`, but Spotlight does not index it.
- `ditto` makes a copy. Spotlight finds it, but each upgrade needs a new
  copy.

The build is signed ad hoc, and every build gets a new signature. macOS may
ask again for access to Keystrand's saved passwords after each upgrade. A
clone built with `scripts/make-signing-cert.sh` and `scripts/install.sh`
signs with a stable self-signed identity that the keychain remembers.

A cask would install straight into `/Applications`. It needs a signed, and
for Gatekeeper notarized, `.app` attached to each GitHub Release. The
release workflow publishes only the source archive, so the tap uses a
formula.

## Create the tap

Do this once, after the first `v*` tag has a GitHub Release.

```bash
gh repo create sstawiarski/homebrew-keystrand --public --clone
cd homebrew-keystrand
mkdir Formula
cp ../keystrand/packaging/homebrew/keystrand.rb Formula/keystrand.rb
```

In `Formula/keystrand.rb`, set the tag in `url` and its `sha256` as described
in the next section. Commit and push.

Users install with:

```bash
brew install sstawiarski/keystrand/keystrand
```

`brew install --HEAD sstawiarski/keystrand/keystrand` builds `main` instead.

## Release a new version

Update the formula by hand for each release. `brew bump-formula-pr` opens a
pull request through a fork, which a tap you push to directly does not need.

1. Tag the release and push the tag. The release workflow creates the
   GitHub Release.

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

2. Hash the source archive GitHub serves for the tag:

   ```bash
   curl -fsSL https://github.com/sstawiarski/keystrand/archive/refs/tags/v0.2.0.tar.gz |
     shasum -a 256
   ```

3. Edit the tapped formula. `brew tap sstawiarski/keystrand` clones the tap, and
   `brew edit` opens the formula in that clone:

   ```bash
   brew tap sstawiarski/keystrand
   brew edit sstawiarski/keystrand/keystrand
   ```

   Change the tag in `url` and set `sha256` to the new hash. Copy any other
   change to `packaging/homebrew/keystrand.rb` in this repository, so both
   copies stay the same apart from the tag and the hash.

4. Check the formula, then remove the test install:

   ```bash
   brew style sstawiarski/keystrand/keystrand
   brew audit --strict --online --formula sstawiarski/keystrand/keystrand
   brew install --build-from-source --formula sstawiarski/keystrand/keystrand
   brew test sstawiarski/keystrand/keystrand
   brew uninstall --formula sstawiarski/keystrand/keystrand
   ```

5. Commit and push from the tap clone:

   ```bash
   cd "$(brew --repository sstawiarski/keystrand)"
   git commit -am "keystrand 0.2.0"
   git push
   ```

Run `brew style` on the formula through a tap, as above. Run on the file in
this repository, it applies Homebrew's rules for its own Ruby code, not its
formula rules.
