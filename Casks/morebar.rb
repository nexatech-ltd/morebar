# Homebrew Cask stub for a future tap. After publishing a GitHub release,
# update `url`, fill in `sha256` (printed by Scripts/package-dmg.sh), and
# drop this file into the tap repository.
cask "morebar" do
  version "0.1.0"
  sha256 "6603b70800e0d6b31ab4a6ceffd5b0bd63588e204eea20fc6e8217967e8043c7"

  url "https://github.com/nexatech-ltd/morebar/releases/download/v#{version}/MoreBar-#{version}.dmg"
  name "MoreBar"
  desc "Second menu bar below the notch for the icons that do not fit"
  homepage "https://github.com/nexatech-ltd/morebar"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "MoreBar.app"

  uninstall quit: "com.nexatech.MoreBar"

  zap trash: [
    "~/Library/Preferences/com.nexatech.MoreBar.plist",
  ]

  caveats <<~EOS
    MoreBar needs the Accessibility and Screen Recording permissions and
    registers itself as a login item on first launch from /Applications.
  EOS
end
