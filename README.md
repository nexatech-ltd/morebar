# MoreBar

A tiny, Apple-native menu bar manager for notched MacBooks running macOS 26+.

On a notched MacBook the system silently parks menu bar icons that do not
fit — they keep running, but you can neither see nor click them. MoreBar puts
a single monochrome "…" item in the menu bar; clicking it slides a second,
Liquid Glass bar in right below the real one with live snapshots of every
hidden third-party icon. Clicking a snapshot temporarily shows the real item,
forwards the click (its menu opens as usual), then tucks it away again.

- No Dock icon, no settings, no About. Right-click the "…" icon to quit.
- Auto light/dark, drawn with the system `NSGlassEffectView`.
- Registers itself as a login item on first launch from `/Applications`.
- No hardcoded app lists: an icon is "system" iff its creating process lives
  under `/System/Library/` (resolved via the Accessibility API on macOS 26,
  where Control Center hosts item windows).

## Permissions

Like every menu bar manager (Bartender, Ice, …), MoreBar needs:

- **Accessibility** — to move other apps' items and forward clicks with
  synthetic events (there is no public API for this).
- **Screen Recording** — to capture snapshots of hidden icons and read
  window names. macOS applies this grant only after an app relaunch;
  MoreBar relaunches itself automatically after a fresh grant.

## Building

```sh
Scripts/build-app.sh        # swift build + assemble + codesign -> build/MoreBar.app
Scripts/package-dmg.sh      # signed DMG -> dist/MoreBar-<version>.dmg
Scripts/notarize.sh         # notarize + staple the app and the DMG
```

Signing uses the Developer ID Application certificate of NexaTech Consulting
(team BG4SARWKL9); notarization expects a `morebar-notary` keychain profile
(`xcrun notarytool store-credentials`).

## Homebrew

`Casks/morebar.rb` is a cask stub for a future tap: publish the DMG as a
GitHub release, fill in the `sha256` printed by `package-dmg.sh`, and drop
the file into the tap repository.

## Implementation notes

The hard parts are ported from [Ice](https://github.com/jordanbaird/Ice)
(MIT), branch `macos-26`:

- hiding uses an expanding 10,000 pt `NSStatusItem` spacer, placed with an
  iterative probe-and-verify dance (on macOS 26 system icons are movable, so
  a mispositioned spacer would push Wi-Fi/Battery off screen — irreversibly);
- item moves/clicks are synthesized `CGEvent` pairs with special fields
  (including the private `0x33` windowID field), trampolined between a
  pid-specific tap and the session tap; all fragile constants live in
  `Sources/MoreBar/Events/ItemClickForwarder.swift`;
- snapshots use `SCScreenshotManager` with `desktopIndependentWindow`
  filters, which captures off-screen windows.
