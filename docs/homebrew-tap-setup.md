# Homebrew Tap Setup Guide

A step-by-step guide to creating and maintaining a Homebrew tap for Diffa.

## Quick Overview

A Homebrew tap is a Git repository containing Formula files (Ruby scripts) that tell Homebrew how to install your software. This guide covers creating your own tap for distributing Diffa.

## Prerequisites

- GitHub account
- Basic understanding of Git
- Homebrew installed (for testing)

## Step 1: Create Your Tap Repository

### Repository Naming Convention

Homebrew taps must follow the naming pattern: `homebrew-{name}`

Examples:
- `homebrew-diffa` - Single tool tap
- `homebrew-tools` - Multiple tools tap
- `homebrew-tap` - Generic name

### Create on GitHub

1. Go to GitHub and create new repository
2. Name it: `homebrew-diffa`
3. Initialize with README
4. Clone locally:
   ```bash
   git clone https://github.com/codelynx/homebrew-diffa.git
   cd homebrew-diffa
   ```

## Step 2: Create Formula Structure

```bash
# Create the Formula directory
mkdir Formula

# Create your formula file
touch Formula/diffa.rb
```

## Step 3: Write Your Formula

Edit `Formula/diffa.rb`:

```ruby
class Diffa < Formula
  desc "Fast file system comparison, patching, and synchronization"
  homepage "https://github.com/codelynx/Diffa"
  license "MIT"
  
  # Version and download URL
  version "0.9.0"
  url "https://github.com/codelynx/Diffa/archive/refs/tags/v#{version}.tar.gz"
  sha256 "PUT_ACTUAL_SHA256_HERE"
  
  # Specify the latest stable version
  stable do
    url "https://github.com/codelynx/Diffa/archive/refs/tags/v#{version}.tar.gz"
    sha256 "PUT_ACTUAL_SHA256_HERE"
  end
  
  # HEAD for installing from main branch
  head "https://github.com/codelynx/Diffa.git", branch: "main"
  
  # Dependencies
  depends_on "swift" => :build  # Build-time only
  depends_on "sqlite"           # Runtime dependency
  
  # Bottles (precompiled binaries) - optional but recommended
  bottle do
    root_url "https://github.com/codelynx/Diffa/releases/download/v#{version}"
    rebuild 0
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "SHA256_HERE"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "SHA256_HERE"
    sha256 cellar: :any_skip_relocation, x86_64_linux:  "SHA256_HERE"
  end
  
  def install
    # Build the project
    system "swift", "build", 
           "--configuration", "release",
           "--disable-sandbox"
    
    # Install the binary
    bin.install ".build/release/diffa"
    
    # Install man pages if they exist
    man1.install "man/diffa.1" if File.exist?("man/diffa.1")
    
    # Install shell completions if they exist
    bash_completion.install "completions/diffa.bash" if File.exist?("completions/diffa.bash")
    zsh_completion.install "completions/_diffa" if File.exist?("completions/_diffa")
  end
  
  def post_install
    # Create working directory
    (var/"diffa").mkpath
  end
  
  def caveats
    <<~EOS
      Diffa has been installed successfully!
      
      Get started with:
        diffa --help
        
      Create your first snapshot:
        diffa snapshot /path/to/directory -o snapshot.diffa
        
      Documentation available at:
        https://github.com/codelynx/Diffa
    EOS
  end
  
  test do
    # Test that the binary runs
    system "#{bin}/diffa", "--version"
    
    # Test basic functionality
    Dir.mktmpdir do |dir|
      # Create test files
      (Pathname(dir)/"test.txt").write("hello")
      
      # Create snapshot
      system "#{bin}/diffa", "snapshot", dir, "-o", "test.diffa"
      
      # Verify snapshot was created
      assert_predicate Pathname("test.diffa"), :exist?
    end
  end
end
```

## Step 4: Calculate SHA256

Get the SHA256 hash of your source tarball:

```bash
# For a specific release
curl -sL https://github.com/codelynx/Diffa/archive/refs/tags/v0.9.0.tar.gz | sha256sum
# Example output: a1b2c3d4e5f6... (use this in your formula)

# Or using brew's built-in command
brew fetch --formula Formula/diffa.rb
```

## Step 5: Test Your Formula

### Local Testing

```bash
# In your tap repository directory
cd homebrew-diffa

# Install from local formula
brew install --build-from-source Formula/diffa.rb

# Test the installation
brew test diffa

# Audit for issues
brew audit --strict diffa

# Check for style issues
brew style Formula/diffa.rb
```

### Fix Common Issues

```bash
# If audit fails with "description is too long"
# Keep description under 80 characters

# If style fails
brew style --fix Formula/diffa.rb
```

## Step 6: Create Bottles (Optional but Recommended)

Bottles are precompiled binaries that make installation faster:

### Building Bottles

```bash
# 1. Install your formula with bottle flag
brew install --build-bottle diffa

# 2. Create bottle files
brew bottle diffa

# This creates files like:
# - diffa--0.9.0.arm64_sonoma.bottle.tar.gz
# - diffa--0.9.0.x86_64_linux.bottle.tar.gz
```

### Upload Bottles

Upload bottle files to your GitHub release:

```bash
# Using GitHub CLI
gh release upload v0.9.0 diffa--0.9.0.*.bottle.tar.gz

# Or manually upload via GitHub web interface
```

### Update Formula with Bottle SHAs

```ruby
bottle do
  root_url "https://github.com/codelynx/Diffa/releases/download/v0.9.0"
  rebuild 0
  sha256 cellar: :any_skip_relocation, arm64_sonoma:  "abc123..."
  sha256 cellar: :any_skip_relocation, arm64_ventura: "def456..."
  sha256 cellar: :any_skip_relocation, x86_64_linux:  "ghi789..."
end
```

## Step 7: Push Your Tap

```bash
git add Formula/diffa.rb
git commit -m "Add diffa formula v0.9.0"
git push origin main
```

## Step 8: Users Install Your Tool

Now users can install Diffa:

```bash
# Add your tap
brew tap codelynx/diffa

# Install
brew install diffa

# Or in one command
brew install codelynx/diffa/diffa
```

## Updating Your Formula

When you release a new version:

### Manual Update

1. Update version in formula
2. Update SHA256 hash
3. Build new bottles (optional)
4. Push changes

### Automated Update Script

Create `update-formula.sh`:

```bash
#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# Download and calculate SHA
URL="https://github.com/codelynx/Diffa/archive/refs/tags/v${VERSION}.tar.gz"
SHA=$(curl -sL "$URL" | sha256sum | cut -d' ' -f1)

# Update formula
sed -i.bak "s/version \".*\"/version \"${VERSION}\"/" Formula/diffa.rb
sed -i.bak "s/sha256 \".*\"/sha256 \"${SHA}\"/" Formula/diffa.rb

# Clean up backup
rm Formula/diffa.rb.bak

echo "Updated formula to version ${VERSION}"
echo "SHA256: ${SHA}"

# Commit and push
git add Formula/diffa.rb
git commit -m "Update diffa to v${VERSION}"
git push
```

## Advanced Features

### Multiple Versions

Support multiple versions simultaneously:

```ruby
class DiffaAT08 < Formula
  desc "Diffa 0.8 (old stable)"
  # ... rest of formula for v0.8
end
```

Users install with: `brew install diffa@0.8`

### Development Builds

Add a `devel` block for pre-releases:

```ruby
devel do
  url "https://github.com/codelynx/Diffa/archive/refs/tags/v1.0.0-beta.1.tar.gz"
  sha256 "SHA256_HERE"
end
```

Users install with: `brew install --devel diffa`

### Platform-Specific Logic

```ruby
def install
  if OS.mac?
    system "swift", "build", "-c", "release"
  elsif OS.linux?
    system "swift", "build", "-c", "release", "--static-swift-stdlib"
  end
  
  bin.install ".build/release/diffa"
end
```

### Services (for daemons)

If your tool includes a daemon:

```ruby
service do
  run [opt_bin/"diffa", "server"]
  keep_alive true
  log_path var/"log/diffa.log"
  error_log_path var/"log/diffa.error.log"
end
```

Users manage with: `brew services start diffa`

## GitHub Actions for Automation

Create `.github/workflows/update.yml` in your tap:

```yaml
name: Update Formula

on:
  repository_dispatch:
    types: [new-release]
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to update to'
        required: true

jobs:
  update-formula:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Update Formula
        env:
          VERSION: ${{ github.event.client_payload.version || github.event.inputs.version }}
        run: |
          ./update-formula.sh "$VERSION"
```

Trigger from main repo when releasing:

```yaml
- name: Update Homebrew Tap
  uses: peter-evans/repository-dispatch@v2
  with:
    token: ${{ secrets.TAP_GITHUB_TOKEN }}
    repository: codelynx/homebrew-diffa
    event-type: new-release
    client-payload: '{"version": "${{ github.ref_name }}"}'
```

## Testing Checklist

Before publishing updates:

- [ ] Formula installs successfully
- [ ] `brew test diffa` passes
- [ ] `brew audit --strict diffa` passes
- [ ] `brew style Formula/diffa.rb` passes
- [ ] Bottles (if any) download correctly
- [ ] Version number is correct
- [ ] SHA256 is correct
- [ ] Works on both macOS and Linux

## Troubleshooting

### Common Issues and Solutions

**"SHA256 mismatch"**
- Recalculate: `curl -sL [URL] | sha256sum`
- Ensure you're using the correct URL

**"undefined method `xyz' for Formula"**
- Check Homebrew documentation for correct DSL
- Run `brew update` to get latest Homebrew

**"Bottle SHA256 mismatch"**
- Rebuild bottles after formula changes
- Ensure bottle files weren't modified after building

**"Permission denied during installation"**
- Don't use `sudo` with brew
- Fix permissions: `sudo chown -R $(whoami) $(brew --prefix)/*`

## Best Practices

1. **Version Management**
   - Keep formula version in sync with releases
   - Use semantic versioning
   - Tag releases properly

2. **Dependencies**
   - Minimize runtime dependencies
   - Use `:build` for build-only dependencies
   - Specify version constraints when needed

3. **Testing**
   - Always test on clean system
   - Test both with and without bottles
   - Test on macOS and Linux

4. **Documentation**
   - Keep formula description concise (<80 chars)
   - Provide helpful caveats
   - Link to documentation in homepage

5. **Bottles**
   - Provide bottles for faster installation
   - Build for multiple OS versions
   - Host on GitHub releases for reliability

## Resources

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Homebrew DSL Documentation](https://rubydoc.brew.sh/Formula)
- [Acceptable Formulae Requirements](https://docs.brew.sh/Acceptable-Formulae)
- [Homebrew Taps Documentation](https://docs.brew.sh/Taps)
- [Example Formulas](https://github.com/Homebrew/homebrew-core/tree/master/Formula)