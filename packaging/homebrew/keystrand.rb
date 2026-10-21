class Keystrand < Formula
  desc "Native Redis and Valkey client for macOS"
  homepage "https://github.com/sstawiarski/keystrand"
  url "https://github.com/sstawiarski/keystrand/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license all_of: ["MIT", "BSD-3-Clause", :cannot_represent]
  head "https://github.com/sstawiarski/keystrand.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on "xcodegen" => :build
  depends_on macos: :tahoe

  def install
    # A release archive has no git history, so only HEAD can use scripts/version.sh.
    if build.head?
      marketing_version = Utils.safe_popen_read("scripts/version.sh").chomp
      build_number = Utils.safe_popen_read("scripts/version.sh", "--build").chomp
    else
      marketing_version = version.to_s
      build_number = version.major_minor_patch.to_s
    end

    system "xcodegen", "generate"
    # Package manifests and macro plugins cannot start their own sandbox
    # inside Homebrew's build sandbox.
    xcodebuild "-IDEPackageSupportDisableManifestSandbox=YES",
               "-project", "Keystrand.xcodeproj",
               "-scheme", "Keystrand",
               "-configuration", "Release",
               "-destination", "platform=macOS",
               "-derivedDataPath", buildpath/"dd",
               "build",
               "ARCHS=#{Hardware::CPU.arch}",
               "MARKETING_VERSION=#{marketing_version}",
               "CURRENT_PROJECT_VERSION=#{build_number}",
               "CODE_SIGN_IDENTITY=-",
               "CODE_SIGNING_ALLOWED=YES",
               "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox"
    prefix.install buildpath/"dd/Build/Products/Release/Keystrand.app"
  end

  def caveats
    <<~EOS
      Keystrand.app is installed in:
        #{opt_prefix}/Keystrand.app

      Formulae cannot write to /Applications. To add the app there, link it
      (the link follows upgrades):
        ln -sfn #{opt_prefix}/Keystrand.app /Applications/Keystrand.app
      or copy it (Spotlight indexes a copy; repeat after each upgrade):
        ditto #{opt_prefix}/Keystrand.app /Applications/Keystrand.app

      This build is signed ad hoc, so macOS may ask again for access to
      Keystrand's saved passwords after each upgrade. For a stable signing
      identity that the keychain remembers, build from a clone instead:
        scripts/make-signing-cert.sh
        scripts/install.sh
    EOS
  end

  test do
    app = prefix/"Keystrand.app"
    unless version.head?
      plist = app/"Contents/Info.plist"
      assert_equal version.to_s,
                   shell_output("/usr/bin/plutil -extract CFBundleShortVersionString raw #{plist}").chomp
    end
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", app
    assert_match(/flags=\S*runtime/, shell_output("/usr/bin/codesign --display --verbose=2 #{app} 2>&1"))
  end
end
