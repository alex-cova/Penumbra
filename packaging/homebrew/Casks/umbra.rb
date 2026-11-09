# Unpublished cask. This file is not in a Homebrew tap.
# `brew install umbra` will not find it until the cask is published
# to a tap or to homebrew/homebrew-cask.
#
# sha256 is the GitHub release asset digest for Umbra-1.6.21-macOS.zip
# (https://github.com/alex-cova/Penumbra/releases/tag/1.6.21).
cask "umbra" do
  version "1.6.21"
  sha256 "c296ae0e44ad8890723c6228416d321a54f66ff769c80a6cf8e107802165406b"

  url "https://github.com/alex-cova/Penumbra/releases/download/#{version}/Umbra-#{version}-macOS.zip"
  name "Umbra"
  desc "Native macOS code editor"
  homepage "https://github.com/alex-cova/Penumbra"

  depends_on macos: ">= :tahoe"

  app "Umbra.app"

  livecheck do
    url "https://github.com/alex-cova/Penumbra/releases/latest"
    regex(/Umbra[._-]v?(\d+(?:\.\d+)+)[._-]macOS\.zip/i)
  end
end
