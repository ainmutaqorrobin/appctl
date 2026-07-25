#!/usr/bin/env bash
#
# release.sh — tag + publish an appctl release in one command.
#
# Usage:
#   ./release.sh                # release the current APPCTL_VERSION as-is
#   ./release.sh patch          # 1.0.0 -> 1.0.1, then release
#   ./release.sh minor          # 1.0.0 -> 1.1.0, then release
#   ./release.sh major          # 1.0.0 -> 2.0.0, then release
#   ./release.sh 1.2.3          # set an explicit version, then release
#
# What it does: (optionally bump APPCTL_VERSION in ./appctl) -> commit any pending
# changes -> create + push an annotated vX.Y.Z tag -> create a GitHub release with
# the appctl script attached and auto-generated notes. The install URL
# (releases/latest/download/appctl) then serves the new version automatically —
# nothing else to edit.
#
# Requires: git, and gh (GitHub CLI) authenticated (`gh auth login`).

set -euo pipefail
cd "$(dirname "$0")"

SCRIPT="appctl"
REPO="ainmutaqorrobin/appctl"

[[ -f "$SCRIPT" ]]            || { echo "error: $SCRIPT not found (run from the repo root)" >&2; exit 1; }
command -v gh  >/dev/null     || { echo "error: gh (GitHub CLI) is required — https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login'" >&2; exit 1; }

# Current version from the script.
cur="$(sed -n 's/^APPCTL_VERSION="\(.*\)"/\1/p' "$SCRIPT")"
[[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: cannot read APPCTL_VERSION from $SCRIPT" >&2; exit 1; }

# Resolve the target version from the argument.
IFS='.' read -r MA MI PA <<< "$cur"
case "${1:-}" in
    "")                    new="$cur" ;;
    patch)                 new="${MA}.${MI}.$((PA+1))" ;;
    minor)                 new="${MA}.$((MI+1)).0" ;;
    major)                 new="$((MA+1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*)  new="$1" ;;
    *) echo "usage: ./release.sh [patch|minor|major|X.Y.Z]" >&2; exit 1 ;;
esac
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid version '$new'" >&2; exit 1; }

tag="v${new}"
git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1 \
    && { echo "error: tag ${tag} already exists — bump to a new version" >&2; exit 1; }

# Bump the version line in-place (cat back to preserve file perms).
if [[ "$new" != "$cur" ]]; then
    sed "s/^APPCTL_VERSION=\".*\"/APPCTL_VERSION=\"${new}\"/" "$SCRIPT" > "$SCRIPT.tmp"
    cat "$SCRIPT.tmp" > "$SCRIPT"; rm -f "$SCRIPT.tmp"
    echo "Bumped ${cur} -> ${new}"
fi

# Commit pending changes (the bump and/or your fixes), if any.
if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A
    git commit -m "chore(release): ${tag}"
fi

# Tag, push, publish. The appctl script is attached as the 'appctl' asset, which
# is what releases/latest/download/appctl resolves to.
branch="$(git rev-parse --abbrev-ref HEAD)"
git tag -a "${tag}" -m "appctl ${tag}"
git push origin "${branch}"
git push origin "${tag}"
gh release create "${tag}" "$SCRIPT" --repo "$REPO" --title "appctl ${tag}" --generate-notes

echo
echo "✔ Published ${tag}"
echo "  Install: curl -fsSL https://github.com/${REPO}/releases/latest/download/appctl | sudo tee /usr/local/bin/appctl >/dev/null && sudo chmod +x /usr/local/bin/appctl"
