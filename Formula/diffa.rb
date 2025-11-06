# Diffa Homebrew Formula
# To install: brew install --formula Formula/diffa.rb
# Or via tap: brew install username/tap/diffa

class Diffa < Formula
  desc "Snapshot, compare, patch, and sync directories"
  homepage "https://github.com/codelynx/diffa"
  url "https://github.com/codelynx/diffa/archive/refs/tags/v0.10.0.tar.gz"
  sha256 "cc492a176bc1e00e83b3f6171fb0ebff6117c56c55d9ef9c19dbdaa44fdd4627"
  license "MIT"
  head "https://github.com/codelynx/diffa.git", branch: "main"

  depends_on :macos => :ventura
  depends_on xcode: ["14.0", :build]

  def install
    # Build release binary
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Install binary
    bin.install ".build/release/diffa"

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
    assert_match version.to_s, shell_output("#{bin}/diffa --version")

    # Create test directory and snapshot
    (testpath/"test-dir").mkpath
    (testpath/"test-dir/file.txt").write("test content")

    system bin/"diffa", "snapshot", testpath/"test-dir",
           "-o", testpath/"test.snapshot"
    assert_predicate testpath/"test.snapshot", :exist?

    # Verify
    system bin/"diffa", "verify", testpath/"test-dir",
           testpath/"test.snapshot"
  end
end
