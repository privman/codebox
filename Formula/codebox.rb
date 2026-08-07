# Homebrew formula for codebox. The `url` and `sha256` lines below are rewritten by
# .github/workflows/release.yml on every release — edit the rest by hand only.
class Codebox < Formula
  desc "Manage a cloud dev VM for Claude Code and code-server"
  homepage "https://github.com/privman/codebox"
  url "https://github.com/privman/codebox/releases/download/v0.1.2/codebox-0.1.2.tar.gz"
  sha256 "ac8234e8f733a61c4f2b5cf4cf7636c526f05a2780cdb9bc07ecbcb99e36ca44"

  def install
    # Keep the tree together — bin/codebox resolves the symlink below to find
    # scripts/ and vm/ next to itself.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/codebox"
  end

  def caveats
    <<~EOS
      codebox drives Google Cloud through gcloud, which is a cask:
        brew install --cask google-cloud-sdk

      Configuration is per project. From the directory you run codebox in:
        cp #{libexec}/codebox.env.example ./codebox.env
    EOS
  end

  test do
    assert_match "codebox #{version}", shell_output("#{bin}/codebox version")
  end
end
