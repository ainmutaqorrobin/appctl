#!/usr/bin/env bash
#
# release.sh — bump the version and push a release tag in one command.
#
# Usage:
#   ./release.sh                # release the current APPCTL_VERSION as-is
#   ./release.sh patch          # 1.0.0 -> 1.0.1, then release
#   ./release.sh minor          # 1.0.0 -> 1.1.0, then release
#   ./release.sh major          # 1.0.0 -> 2.0.0, then release
#   ./release.sh 1.2.3          # set an explicit version, then release
#
# What it does: (optionally bump APPCTL_VERSION in ./appctl) -> commit any pending
# changes -> create + push an annotated vX.Y.Z tag. Pushing the tag triggers the
# GitHub Actions workflow (.github/workflows/release.yml), which publishes the
# GitHub release with the appctl script attached and auto-generated notes. The
# install URL (releases/latest/download/appctl) then serves the new version.
#
# Requires: git only. The release itself is created by CI — no local gh needed.

set -euo pipefail
cd "$(dirname "$0")"

SCRIPT="appctl"
REPO="ainmutaqorrobin/appctl"

[[ -f "$SCRIPT" ]] || { echo "error: $SCRIPT not found (run from the repo root)" >&2; exit 1; }

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

# Tag + push. Pushing the tag triggers the release workflow, which creates the
# GitHub release and attaches the appctl script as the 'appctl' asset (what
# releases/latest/download/appctl resolves to).
branch="$(git rev-parse --abbrev-ref HEAD)"
git tag -a "${tag}" -m "appctl ${tag}"
git push origin "${branch}"
git push origin "${tag}"

echo
echo "✔ Pushed ${tag} — GitHub Actions is now publishing the release."
echo "  Watch:   https://github.com/${REPO}/actions"
echo "  Release: https://github.com/${REPO}/releases/tag/${tag}"
