cask "timetaggerbar" do
  version "0.9.0"
  sha256 "93a2482cdb82940b5a80d0d349164502ffc29417b5995c413f7bfa43af66b291"

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
