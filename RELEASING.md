# Releasing MoreBar

## 1. Build, sign, notarize

```sh
VERSION=0.2.0 Scripts/build-app.sh      # build + codesign (Developer ID Application)
VERSION=0.2.0 Scripts/notarize.sh       # notarize+staple the app, rebuild the DMG, notarize+staple it
```

Prerequisite (one-time per machine): a `morebar-notary` keychain profile —
`xcrun notarytool store-credentials morebar-notary --apple-id <apple-id> --team-id BG4SARWKL9`
(app-specific password, or better an App Store Connect API key via `--key/--key-id/--issuer`).

The result is `dist/MoreBar-<version>.dmg`; `package-dmg.sh`/`notarize.sh` print its sha256.

## 2. Publish on GitHub

1. Create the public repo (e.g. `github.com/nexatech-ltd/morebar`) and push this project.
2. Tag and release:

```sh
git tag v0.2.0 && git push origin main --tags
gh release create v0.2.0 dist/MoreBar-0.2.0.dmg --title "MoreBar 0.2.0" --notes "…"
```

## 3. Homebrew tap (instant, recommended first)

Homebrew installs casks from any GitHub repo named `homebrew-<tap>`:

1. Create a public repo `github.com/nexatech-ltd/homebrew-tap` with a `Casks/` directory.
2. Copy `Casks/morebar.rb` there; set the real `url` (the GitHub release asset)
   and the `sha256` printed by the packaging script; keep `version` in sync.
3. Users install with:

```sh
brew tap nexatech-ltd/tap
brew install --cask morebar
```

Each new release = update `version`, `url` (implicit via version) and `sha256`
in the tap repo. This can be automated later with a GitHub Action
(`brew bump-cask-pr` works against taps too).

## 4. Official homebrew/cask (later, optional)

The official repo accepts apps that meet notability criteria (the audit
checks GitHub stars/forks/watchers of the upstream repo, ~75 stars is the
usual bar; niche or brand-new apps get rejected). Once MoreBar has traction:

```sh
brew tap homebrew/cask
brew create --cask https://github.com/nexatech-ltd/morebar/releases/download/v0.2.0/MoreBar-0.2.0.dmg --set-name morebar
brew audit --cask --new morebar && brew style --fix morebar
# open a PR against github.com/Homebrew/homebrew-cask
```

The cask file itself is the same one from `Casks/morebar.rb`.

## Checklist per release

- [ ] bump VERSION in the build commands (Info.plist gets it automatically)
- [ ] `Scripts/notarize.sh` passed (`accepted`, stapled)
- [ ] GitHub release with the DMG asset
- [ ] tap repo: version + sha256 updated
