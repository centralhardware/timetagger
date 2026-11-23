cask "timetaggerbar" do
  version "0.8.4"
  sha256 "da5f77e6d582a82261597b405e40e8c475c874b34527ed955098eeb99c9b7141"

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
