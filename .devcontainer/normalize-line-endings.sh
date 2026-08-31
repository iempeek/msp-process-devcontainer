#!/bin/sh
# =============================================================================
# .devcontainer/normalize-line-endings.sh
#
# Strips CR from the shell scripts in this workspace, in place.
#
# WHY THIS EXISTS: git-for-windows ships with core.autocrlf=true, so on a
# Windows host every tracked .sh can land on disk with CRLF. A CRLF script is
# not merely ugly, it does not run at all - the \r is part of the last token on
# every line, including the shebang:
#
#   /usr/bin/env: 'bash\r': No such file or directory      <- shebang
#   host-bootstrap.sh: set: line 37: illegal option -       <- first command
#
# .gitattributes (workspace root, and one per product checkout) forces LF for
# every FRESH checkout, which is the actual fix. This script is the repair pass
# for the checkouts that already exist on disk - including the two product
# repos, whose Claude hooks (.claude/adlc-scripts/*.sh) fail exactly this way -
# so a Windows dev is not required to run `git add --renormalize` in three repos
# before anything works. It is a no-op on an already-LF tree, and it is safe to
# run repeatedly.
#
# It is called with the workspace root as $1 from host-bootstrap.sh, i.e. from
# inside the throwaway alpine container of initializeCommand, before the
# devcontainer is created - so the scripts are already LF by the time anything
# in the container, or any agent hook, tries to execute them. Plain POSIX sh
# and no dependency beyond grep/tr/cat, because that is all alpine has. Run it
# by hand from inside the container the same way:
#
#   sh .devcontainer/normalize-line-endings.sh /workspaces/<workspace>
#
# WRITES ARE BEST EFFORT. On Windows the workspace is a Docker Desktop bind
# mount where an individual file can refuse writes (read-only attribute, or an
# ACL granting nothing to the container user); that must produce a warning, not
# a failed container start. `cat > file` truncates in place instead of
# replacing the inode, so ownership and any hardlink survive - which also keeps
# root, the user this runs as in alpine, from taking files over on a Linux host.
# =============================================================================
set -u

WS="${1:-}"
[ -n "$WS" ] || { echo "usage: normalize-line-endings.sh <workspace-root>" >&2; exit 2; }
[ -d "$WS" ] || { echo "[ERROR] normalize-line-endings: no such directory: $WS" >&2; exit 2; }

# Folder names of the two product checkouts, same defaults as devcontainer.json
# (containerEnv is NOT visible to initializeCommand, so they cannot simply be
# inherited from there).
BE="$WS/${BACKEND_DIR_NAME:-MSPProcess}"
FE="$WS/${FRONTEND_DIR_NAME:-mspprocess-ui}"

CR="$(printf '\r')"
CHANGED=0
FAILED=0

# Deliberately GLOBS, not a recursive `find`. On Windows every path lookup goes
# through the Docker Desktop share, so walking a 106-project .NET tree plus
# node_modules would cost far more than the pass is worth. These are the only
# scripts anything here actually executes: this devcontainer's own, each repo's
# top-level helpers, and the agent hooks in .claude/adlc-scripts (which is also
# why the ADLC worktrees are covered - agents run inside them).
scan_globs() {
  echo "$WS"/.devcontainer/*.sh
  echo "$BE"/*.sh
  echo "$BE"/.claude/adlc-scripts/*.sh
  echo "$BE"/.worktrees/*/*.sh
  echo "$BE"/.worktrees/*/.claude/adlc-scripts/*.sh
  echo "$BE"/.worktrees/*/.devcontainer/*.sh
  echo "$FE"/*.sh
  echo "$FE"/.claude/adlc-scripts/*.sh
}

# Unmatched globs come back as the literal pattern, so every candidate is
# re-tested with -f before it is touched.
for f in $(scan_globs); do
  [ -f "$f" ] || continue
  [ -r "$f" ] || continue
  grep -q "$CR" "$f" 2>/dev/null || continue

  if { tr -d '\r' < "$f" > /tmp/nle.$$ && cat /tmp/nle.$$ > "$f"; } 2>/dev/null; then
    echo "[INFO] normalize-line-endings: CRLF -> LF in ${f#"$WS"/}"
    CHANGED=$((CHANGED + 1))
  else
    echo "[WARNING] normalize-line-endings: cannot rewrite ${f#"$WS"/} - it will fail to run." >&2
    FAILED=$((FAILED + 1))
  fi
  rm -f /tmp/nle.$$
done

if [ "$FAILED" -gt 0 ]; then
  echo "[WARNING] normalize-line-endings: $FAILED file(s) still have CRLF and could not be" >&2
  echo "[WARNING] rewritten. On Windows, from the workspace folder in cmd:" >&2
  echo "[WARNING]   attrib -r <file>        (clear the read-only attribute)" >&2
  echo "[WARNING] or fix it in git, per repo:" >&2
  echo "[WARNING]   git add --renormalize . && git checkout -- ." >&2
fi

[ "$CHANGED" = 0 ] || echo "[INFO] normalize-line-endings: normalized $CHANGED file(s)."

# Never fail the caller: this is a repair pass. A file it could not fix is
# reported above, and the thing that needs it will fail loudly on its own.
exit 0
