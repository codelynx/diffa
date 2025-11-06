# Diffalla Homebrew Formula
# To install: brew install --formula Formula/diffalla.rb
# Or via tap: brew install username/tap/diffalla

class Diffalla < Formula
  desc "Snapshot, compare, patch, and sync directories"
  homepage "https://github.com/codelynx/Diffalla"
  url "https://github.com/codelynx/Diffalla/archive/refs/tags/v0.10.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"
  head "https://github.com/codelynx/Diffalla.git", branch: "main"

  depends_on :macos => :ventura
  depends_on xcode: ["14.0", :build]

  def install
    # Build release binary
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Install binary
    bin.install ".build/release/diffalla"

    # Install man pages
    man1.install Dir["man/man1/*.1"]

    # Install documentation
    doc.install "README.md"
    doc.install "docs/cli-design.md" => "CLI-DESIGN.md"

    # Install examples
    (doc/"examples").install Dir["examples/*"]
  end

  test do
    # Basic version check
    assert_match version.to_s, shell_output("#{bin}/diffalla --version")

    # Create test directory and snapshot
    (testpath/"test-dir").mkpath
    (testpath/"test-dir/file.txt").write("test content")

    system bin/"diffalla", "snapshot", testpath/"test-dir",
           "-o", testpath/"test.snapshot"
    assert_predicate testpath/"test.snapshot", :exist?

    # Verify
    system bin/"diffalla", "verify", testpath/"test-dir",
           testpath/"test.snapshot"
  end
end
