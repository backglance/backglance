# The seed for backglance/homebrew-tap — see Scripts/tap/README.md. After the tap
# exists, the tap's copy is canonical and this file is not read by anything.
# version and sha256 are placeholders; the first release's bump rewrites both.
cask "backglance" do
  version "1.0.0"
  sha256 "3f0c1a9b8e7d6c5b4a39281706f5e4d3c2b1a0998877665544332211aabbccdd"

  url "https://github.com/backglance/backglance/releases/download/v#{version}/Backglance-#{version}.zip"
  name "Backglance"
  desc "Searchable local archive of notifications, in the menu bar"
  homepage "https://github.com/backglance/backglance"

  # `brew livecheck backglance` reads the latest non-prerelease GitHub Release tag (vX.Y.Z)
  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself with Sparkle; brew upgrade is not the only path.
  auto_updates true
  depends_on macos: :sonoma

  app "Backglance.app"

  uninstall quit:       "app.backglance.Backglance",
            login_item: "Backglance"

  # `brew uninstall --zap backglance` also removes user data. Order matters to nobody; the list is
  # everything Backglance writes: archive + icon cache + tmp snapshots, logs, preferences, caches.
  zap trash: [
    "~/Library/Application Support/Backglance",
    "~/Library/Caches/app.backglance.Backglance",
    "~/Library/Logs/Backglance",
    "~/Library/Preferences/app.backglance.Backglance.plist",
  ]
end
