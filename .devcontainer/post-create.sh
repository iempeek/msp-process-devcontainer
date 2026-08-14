#!/usr/bin/env bash
# =============================================================================
# .devcontainer/post-create.sh
#
# Runs ONCE when the devcontainer is created (postCreateCommand).
# Recurring startup work (infra network/dirs/relay) lives in infra-up.sh
# instead; the sidecars themselves start on demand via local-stack.sh --run.
#
# Design rules:
#   * Every step is an idempotent function - safe to re-run on rebuilds.
#   * CORE steps (apt toolbox, symlinks, worktrees) hard-fail: without them
#     the container is broken, so creation SHOULD abort.
#   * OPTIONAL tools (scanners, omnisharp) soft-fail: a flaky download must
#     not brick container creation. Failures are collected and reported at
#     the end; re-run `bash .devcontainer/post-create.sh` to retry.
#   * Add a new tool? Write a function, register it in main().
# =============================================================================
set -euo pipefail

# Pinpoints the exact failing command+line instead of the devcontainer CLI's
# anonymous "Command failed: postCreateCommand" wall of JS stack trace.
trap 'echo "[ERROR] post-create.sh failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

# Failures from OPTIONAL tools accumulate here; reported in main() summary.
FAILED_OPTIONAL=()

# This devcontainer is SHARED by the backend and frontend checkouts, which sit
# side by side inside the workspace it opens. Steps below that are specific to
# one checkout (worktrees, AGENTS.md, the .claude quality gates, dotnet restore)
# resolve it here and skip themselves when it is absent, so a frontend-only
# clone still creates cleanly.
WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_ROOT="$WS_ROOT/${BACKEND_DIR_NAME:-MSPProcess}"

# run_optional <name> <function> - runs an installer without killing the
# script on failure. The function is executed in a SEPARATE bash process
# with its own errexit: inside `if fn; then`, bash suspends `set -e` for
# the whole function body, so a failed curl would otherwise be masked by
# a succeeding cleanup command and report a bogus "ok".
run_optional() {
  local name="$1" fn="$2"
  echo "==> ${name}"
  if bash -euo pipefail -c "$(declare -f "$fn"); $fn"; then
    echo "    ok"
  else
    echo "    [WARNING] ${name} failed - continuing. Re-run this script to retry." >&2
    FAILED_OPTIONAL+=("$name")
  fi
}

# =============================================================================
# CORE - hard failures abort container creation
# =============================================================================

# -----------------------------------------------------------------------------
# Base CLI toolbox via apt. Skips apt entirely if already present
# (ripgrep is the sentinel: if rg exists, the batch was installed before).
# Add/remove packages: edit the list below.
# -----------------------------------------------------------------------------
install_apt_toolbox() {
  if command -v rg >/dev/null 2>&1; then
    echo "apt toolbox: already installed, skipping."
    return 0
  fi
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends \
    ripgrep fd-find fzf jq bat tree \
    less procps htop unzip zip \
    build-essential pkg-config \
    sqlite3 shellcheck moreutils tmux \
    curl ca-certificates
  sudo apt-get clean
  sudo rm -rf /var/lib/apt/lists/*
}

# -----------------------------------------------------------------------------
# Debian/Ubuntu ship fd as "fdfind" and bat as "batcat" (name collisions).
# Agents and muscle memory expect the canonical names - symlink them.
# -----------------------------------------------------------------------------
link_renamed_debian_binaries() {
  command -v fd  >/dev/null 2>&1 || sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  command -v bat >/dev/null 2>&1 || sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
}

# -----------------------------------------------------------------------------
# Git worktrees setup. Devcontainers only bind-mount the workspace itself, so
# worktrees must live INSIDE it (../ is root-owned /workspaces) - and inside the
# backend checkout specifically, since that is the repo they branch from.
# -----------------------------------------------------------------------------
# AGENTS.md is a symlink to CLAUDE.md so every harness reads one file. Editors
# that replace a file instead of writing through it (write temp + rename) turn
# the symlink back into a regular copy, which then silently diverges - restore
# it. A regular file whose content DIFFERS is somebody's real edit: warn and
# leave it, rather than deleting work.
restore_agents_symlink() {
  local root="$BACKEND_ROOT"
  [ -f "$root/CLAUDE.md" ] || return 0
  [ -L "$root/AGENTS.md" ] && return 0

  if [ -e "$root/AGENTS.md" ] && ! cmp -s "$root/AGENTS.md" "$root/CLAUDE.md"; then
    echo "[WARNING] AGENTS.md is a regular file and differs from CLAUDE.md - leaving it." >&2
    echo "[WARNING] Merge the difference, then: ln -sf CLAUDE.md AGENTS.md" >&2
    return 0
  fi
  ln -sfn CLAUDE.md "$root/AGENTS.md"
  echo "[INFO] restored AGENTS.md -> CLAUDE.md symlink"
}

setup_worktrees_dir() {
  # ADLC worktrees belong to the backend checkout, not to the shared workspace.
  if [ -d "$BACKEND_ROOT/.git" ] || [ -f "$BACKEND_ROOT/.git" ]; then
    mkdir -p "$BACKEND_ROOT/.worktrees"
    grep -qx '.worktrees/' "$BACKEND_ROOT/.gitignore" 2>/dev/null \
      || echo '.worktrees/' >> "$BACKEND_ROOT/.gitignore"
  fi
  # .env holds real tokens (see runArgs --env-file) and now lives at the
  # workspace root, so it is the DEVCONTAINER repo that must ignore it.
  grep -qx '.env' "$WS_ROOT/.gitignore" 2>/dev/null || echo '.env' >> "$WS_ROOT/.gitignore"
}

# =============================================================================
# OPTIONAL - soft failures logged, container creation continues
# =============================================================================

# -----------------------------------------------------------------------------
# Claude Code via the OFFICIAL native installer. npm is the legacy path - the
# native build lands at ~/.local/bin/claude and self-updates in the background,
# so version bumps never need a container rebuild.
# Docs: https://code.claude.com/docs/en/setup
# Pin a channel/version: `| bash -s stable` or `| bash -s 2.1.89`.
# -----------------------------------------------------------------------------
install_claude_code() {
  # Legacy npm install shadows the native one on PATH - drop it first.
  if npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
    npm uninstall -g @anthropic-ai/claude-code
  fi
  [ -x "$HOME/.local/bin/claude" ] && return 0
  curl -fsSL https://claude.ai/install.sh | bash
}

# -----------------------------------------------------------------------------
# opencode - second terminal agent harness alongside Claude Code. Its installer
# drops the binary in ~/.opencode/bin; --no-modify-path keeps shell rc files
# untouched and the /usr/local/bin symlink (same trick as omnisharp) puts it on
# PATH for every shell, login or not.
# Docs: https://opencode.ai/docs/
# Pin a version: `| bash -s -- --version 1.0.180 --no-modify-path`.
# -----------------------------------------------------------------------------
install_opencode() {
  command -v opencode >/dev/null 2>&1 && return 0
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
  sudo ln -sf "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode
}

# -----------------------------------------------------------------------------
# Codex CLI - OpenAI's terminal agent, third harness alongside Claude Code and
# opencode. npm-installed (the official channel) at latest; version bumps don't
# need a container rebuild - re-run this script or `npm update -g @openai/codex`.
# Docs: https://developers.openai.com/codex/cli
# Pin a version: `npm install -g @openai/codex@0.46.0`.
# -----------------------------------------------------------------------------
install_codex() {
  command -v codex >/dev/null 2>&1 && return 0
  npm install -g @openai/codex@latest
}

# -----------------------------------------------------------------------------
# GitHub Copilot CLI - GitHub's terminal agent (command: copilot), fourth
# harness alongside Claude Code, opencode and codex. npm-installed at latest;
# re-run this script or `npm update -g @github/copilot` to bump.
# Docs: https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli
# Pin a version: `npm install -g @github/copilot@0.0.334`.
# -----------------------------------------------------------------------------
install_copilot_cli() {
  command -v copilot >/dev/null 2>&1 && return 0
  npm install -g @github/copilot@latest
}

# -----------------------------------------------------------------------------
# ast-grep - structural code search/rewrite. npm-installed so version bumps
# don't force a container rebuild; just re-run this script.
# -----------------------------------------------------------------------------
install_ast_grep() {
  command -v ast-grep >/dev/null 2>&1 || npm install -g @ast-grep/cli
}

# -----------------------------------------------------------------------------
# Quality-gate scanners (trivy, qodana, snyk, sonar-scanner, ...) - each lives
# in the backend checkout's .claude/adlc-scripts/<name>.sh and installs itself
# via `<name>.sh --install`.
# Driven dynamically by that repo's .claude/adlc.config.json qualityGates[]: every entry
# with "enabled": true whose name ends in .sh gets installed. Register a new
# scanner just by adding it to that config - nothing to edit here.
# -----------------------------------------------------------------------------
install_quality_gate_scanners() {
  # The .claude harness stays in the backend checkout, so the config and the
  # scanner scripts are read from there, not from the shared workspace root.
  local config="$BACKEND_ROOT/.claude/adlc.config.json"
  local scripts_dir="$BACKEND_ROOT/.claude/adlc-scripts"
  [ -f "$config" ] || return 0

  local script version
  while IFS=$'\t' read -r script version; do
    [ -n "$script" ] || continue
    echo "==> ${script} (quality gate, version ${version:-<missing>})"
    if bash "$scripts_dir/$script" --install "$version"; then
      echo "    ok"
    else
      echo "    [WARNING] ${script} failed - continuing. Re-run this script to retry." >&2
      FAILED_OPTIONAL+=("$script")
    fi
  done < <(jq -r '(.qualityGates // [])[] | select(.enabled == true) | select(.name | endswith(".sh")) | "\(.name)\t\(.version // "")"' "$config")
}

# -----------------------------------------------------------------------------
# uv - fast Python package/project manager (uv, uvx). Also provides the Python
# interpreter itself (see install_python). Installed straight from GitHub
# releases, same deterministic pattern as trivy/qodana.
# Docs: https://docs.astral.sh/uv/
# Usage: uv venv / uv pip install / uv sync / uvx <tool>
# -----------------------------------------------------------------------------
install_uv() {
  command -v uv >/dev/null 2>&1 && return 0
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
  tar xzf "$tmp/uv.tar.gz" -C "$tmp" --strip-components=1
  sudo install -m 0755 "$tmp/uv"  /usr/local/bin/uv
  sudo install -m 0755 "$tmp/uvx" /usr/local/bin/uvx
  rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# Global Python via uv. The base image only ships python3-minimal, whose stdlib
# is gutted - even `import json` fails - so install a complete uv-managed
# CPython. uv shims it into ~/.local/bin, which sits AFTER /usr/bin on PATH, so
# `python3` would still hit the broken one; the /usr/local/bin symlinks (same
# trick as fd/bat/omnisharp) win instead. Absolute-path shebangs like
# /usr/bin/python3 in system scripts are untouched.
# Requires install_uv to have run. Pin a version: `uv python install 3.13 ...`.
# -----------------------------------------------------------------------------
install_python() {
  if [ ! -x "$HOME/.local/bin/python3" ]; then
    uv python install --default --preview-features python-install-default
  fi
  sudo ln -sf "$HOME/.local/bin/python"  /usr/local/bin/python
  sudo ln -sf "$HOME/.local/bin/python3" /usr/local/bin/python3

  # uv shims python but not pip. Delegate via `-m pip` so these keep working
  # across Python upgrades instead of pinning a versioned install path.
  printf '#!/usr/bin/env bash\nexec "%s/.local/bin/python3" -m pip "$@"\n' "$HOME" \
    | sudo tee /usr/local/bin/pip3 >/dev/null
  sudo chmod 0755 /usr/local/bin/pip3
  sudo ln -sf /usr/local/bin/pip3 /usr/local/bin/pip
}

# -----------------------------------------------------------------------------
# OmniSharp standalone - headless C# LSP server, usable outside VS Code.
# (VS Code's C# extension manages its own copy; this one is for scripting/CI.)
# Docs: https://github.com/OmniSharp/omnisharp-roslyn
# Usage: omnisharp -s /workspaces/<repo> -lsp
# -----------------------------------------------------------------------------
# Browser for the `playwright` MCP server (.mcp.json), which is how an agent
# looks at the running frontend. The MCP package itself ships NO browser - it
# drives an installed one, and its default is the Chrome *channel*, i.e. a real
# system Chrome installed through apt (not a download into ~/.cache).
# Preinstalled here so the first MCP call doesn't stall on a several-hundred-MB
# install. `sudo npx` can't see the nvm-managed node, hence the explicit PATH.
install_playwright_browser() {
  command -v google-chrome >/dev/null 2>&1 && return 0
  sudo -E env "PATH=$PATH" npx --yes playwright@latest install --with-deps chrome
  google-chrome --version
}

install_omnisharp() {
  command -v omnisharp >/dev/null 2>&1 && return 0
  local dir=/opt/omnisharp
  sudo mkdir -p "$dir"
  curl -fsSL https://github.com/OmniSharp/omnisharp-roslyn/releases/latest/download/omnisharp-linux-x64-net6.0.tar.gz \
    | sudo tar xz -C "$dir"
  sudo ln -sf "$dir/OmniSharp" /usr/local/bin/omnisharp
}

# =============================================================================
# Entry point
# =============================================================================
main() {
  # Core - abort on failure
  install_apt_toolbox
  link_renamed_debian_binaries
  setup_worktrees_dir
  restore_agents_symlink

  # Optional - warn on failure, keep going
  run_optional "claude code (native installer)"     install_claude_code
  run_optional "opencode"                           install_opencode
  run_optional "codex cli"                          install_codex
  run_optional "github copilot cli"                 install_copilot_cli
  run_optional "ast-grep"                           install_ast_grep
  run_optional "uv (python package manager)"        install_uv
  run_optional "python (uv-managed, global)"        install_python
  install_quality_gate_scanners
  run_optional "omnisharp"                          install_omnisharp
  run_optional "chrome (for the playwright MCP)"    install_playwright_browser

  if [ "${#FAILED_OPTIONAL[@]}" -gt 0 ]; then
    echo ""
    echo "[WARNING] Container is usable, but these optional tools failed to install:"
    printf '    - %s\n' "${FAILED_OPTIONAL[@]}"
    echo "    Retry with: bash .devcontainer/post-create.sh"
  fi

  echo "ADLC devcontainer ready."

  # Project setup - dotnet restore, run last so all tooling above is in place.
  bash "$(dirname "${BASH_SOURCE[0]}")/project-setup.sh"
}

main "$@"
