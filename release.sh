#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.8.0" >&2
}

die() {
  echo "release.sh: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || {
  usage
  exit 2
}

version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "version must use the X.Y.Z format"

for command in curl git grep makepkg mktemp sed sha256sum; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aur_dir=$(cd -- "$repo_dir/../../aur/zur" 2>/dev/null && pwd) ||
  die "AUR repository not found at $repo_dir/../../aur/zur"
pkgbuild=$aur_dir/PKGBUILD

[[ -f $pkgbuild ]] || die "PKGBUILD not found at $pkgbuild"
git -C "$repo_dir" remote get-url origin >/dev/null 2>&1 ||
  die "the source repository has no origin remote"
git -C "$aur_dir" remote get-url origin >/dev/null 2>&1 ||
  die "the AUR repository has no origin remote"
git -C "$aur_dir" symbolic-ref --quiet HEAD >/dev/null ||
  die "the AUR repository is in detached HEAD state"
git -C "$aur_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
  die "the current AUR branch has no upstream"
git -C "$aur_dir" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
  die "git author information is not configured for the AUR repository"

# Do not mix a release with pre-existing tracked or staged changes. Untracked
# makepkg output in the AUR repository is intentionally ignored.
git -C "$repo_dir" diff --quiet --ignore-submodules -- ||
  die "the source repository has uncommitted tracked changes"
git -C "$repo_dir" diff --cached --quiet --ignore-submodules -- ||
  die "the source repository has staged changes"
git -C "$aur_dir" diff --quiet --ignore-submodules -- ||
  die "the AUR repository has uncommitted tracked changes"
git -C "$aur_dir" diff --cached --quiet --ignore-submodules -- ||
  die "the AUR repository has staged changes"

grep -Fq ".version = \"$version\"" "$repo_dir/build.zig.zon" ||
  die "build.zig.zon does not declare version $version"
[[ $(grep -Ec '^pkgver=' "$pkgbuild") -eq 1 ]] ||
  die "expected exactly one pkgver entry in PKGBUILD"
[[ $(grep -Ec '^sha256sums=' "$pkgbuild") -eq 1 ]] ||
  die "expected exactly one sha256sums entry in PKGBUILD"

git -C "$repo_dir" rev-parse --verify --quiet "refs/tags/$version" >/dev/null &&
  die "tag $version already exists locally"
if git -C "$repo_dir" ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null; then
  die "tag $version already exists on origin"
else
  status=$?
  [[ $status -eq 2 ]] || die "could not query tags on origin"
fi
git -C "$aur_dir" ls-remote origin HEAD >/dev/null ||
  die "could not connect to the AUR origin"

echo "Tagging $version and pushing it to GitHub..."
git -C "$repo_dir" tag "$version"
git -C "$repo_dir" push origin "refs/tags/$version"

archive_url="https://github.com/hspak/zur/archive/refs/tags/$version.tar.gz"
archive=$(mktemp --suffix="-$version.tar.gz")
trap 'rm -f -- "$archive"' EXIT

echo "Downloading the tagged source archive..."
curl --fail --location --silent --show-error \
  --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$archive" "$archive_url"
sha256=$(sha256sum "$archive")
sha256=${sha256%% *}
echo "SHA-256: $sha256"

echo "Updating the AUR package..."
sed -Ei "s/^pkgver=.*/pkgver=$version/" "$pkgbuild"
sed -Ei "s/^sha256sums=.*/sha256sums=(\"$sha256\")/" "$pkgbuild"

(
  cd -- "$aur_dir"
  makepkg --printsrcinfo >.SRCINFO
  makepkg
  git add -- PKGBUILD .SRCINFO
  git commit -m "Publish version $version"
  git push
)

echo "Published zur $version to GitHub and the AUR."
