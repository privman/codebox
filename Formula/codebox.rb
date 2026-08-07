# Homebrew formula for codebox. The `url` and `sha256` lines below are rewritten by
# .github/workflows/release.yml on every release — edit the rest by hand only.
class Codebox < Formula
  desc "Manage a cloud dev VM for Claude Code and code-server"
  homepage "https://github.com/privman/codebox"
  url "https://github.com/privman/codebox/releases/download/v0.1.1/codebox-0.1.1.tar.gz"
  sha256 "057ca4a3ee56ee1eb9ddbac3999beee30fe62504c97b34c3d5263ebec0275a0e"

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
