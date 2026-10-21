# Developer tools for Keystrand. Install with scripts/bootstrap.sh.
# jq ships with macOS and is not listed.

# Build
brew "xcodegen"

# Formatting and lint
brew "swiftformat"
brew "ast-grep"
brew "markdownlint-cli"
brew "shellcheck"
brew "ruff"

# Native test servers for scripts/test-servers.sh. Valkey links its own
# redis-server and redis-cli, so Redis stays unlinked: run it from
# $(brew --prefix redis)/bin. CI skips both with
# HOMEBREW_BUNDLE_BREW_SKIP="redis valkey".
brew "redis", link: false
brew "valkey"
