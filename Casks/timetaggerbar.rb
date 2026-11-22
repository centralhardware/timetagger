cask "timetaggerbar" do
  version "0.9.1"
  sha256 "5b82080da748975222223cd7266d0d44e4e674b7d5077e6456eca64f03326cad"

  url "https://github.com/centralhardware/timetagger/releases/download/macos-v#{version}/TimeTaggerBar-#{version}.dmg"
  name "TimeTaggerBar"
  desc "Menu-bar client for TimeTagger"
  homepage "https://github.com/centralhardware/timetagger"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "TimeTaggerBar.app"

  # The app is signed with a self-signed certificate, not notarized: without this,
  # Gatekeeper refuses the first launch just like a hand-downloaded dmg.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/TimeTaggerBar.app"]
  end

  zap trash: "~/Library/Preferences/app.timetagger.bar.plist"
end
