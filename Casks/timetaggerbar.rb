cask "timetaggerbar" do
  version "0.8.6"
  sha256 "d0e6a74d5661c677641443b604fdb3696f2cc77b07b79140aa341783a4d14198"

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
