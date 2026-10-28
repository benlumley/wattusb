#!/bin/sh
# Prints the version the release workflow should publish for HEAD.
#
#   scripts/next-version.sh <base-version>
#
# <base-version> is CFBundleShortVersionString from Info.plist (X.Y.Z).
# - If HEAD already carries a vX.Y.Z tag, print that version (re-runs reuse it).
# - Else if a later vX.Y.Z tag already contains HEAD, print nothing (skip).
# - Else if <base-version> is newer than the latest vX.Y.Z tag, print it
#   (bump Info.plist to start a new minor/major line).
# - Else print the latest tag with its patch number incremented.
set -eu

base=${1:?usage: next-version.sh <base-version>}
semver='^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'

if ! printf '%s\n' "$base" | grep -Eq "$semver"; then
  echo "Base version '$base' is not X.Y.Z" >&2
  exit 1
fi

existing=$(git tag --points-at HEAD --list 'v*' | sed 's/^v//' | grep -E "$semver" | sort -V | tail -n 1 || true)
if [ -n "$existing" ]; then
  echo "$existing"
  exit 0
fi

# A later release already includes HEAD (e.g. an older run finished last):
# print nothing so the workflow skips instead of shipping older code as latest.
if git tag --contains HEAD --list 'v*' | sed 's/^v//' | grep -Eq "$semver"; then
  exit 0
fi

latest=$(git tag --list 'v*' | sed 's/^v//' | grep -E "$semver" | sort -V | tail -n 1 || true)
if [ -z "$latest" ]; then
  echo "$base"
  exit 0
fi

highest=$(printf '%s\n%s\n' "$base" "$latest" | sort -V | tail -n 1)
if [ "$highest" = "$base" ] && [ "$base" != "$latest" ]; then
  echo "$base"
  exit 0
fi

major=${latest%%.*}
rest=${latest#*.}
minor=${rest%%.*}
patch=${rest#*.}
echo "$major.$minor.$((patch + 1))"
