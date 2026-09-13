#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$project_dir/dist}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/wallpaper-browser-build.XXXXXX")"
archive_path="$build_dir/wallpaper-browser.xcarchive"
derived_data_path="$build_dir/DerivedData"

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

cd "$project_dir"
git_commit="$(git rev-parse HEAD)"

settings="$(xcodebuild \
  -project wallpaper-browser.xcodeproj \
  -scheme wallpaper-browser \
  -configuration Release \
  -derivedDataPath "$derived_data_path" \
  -showBuildSettings 2>/dev/null)"
marketing_version="$(printf '%s\n' "$settings" | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
if [[ -z "$marketing_version" ]]; then
  echo "Unable to read MARKETING_VERSION from Xcode build settings." >&2
  exit 1
fi

mkdir -p "$output_dir"

xcodebuild archive \
  -project wallpaper-browser.xcodeproj \
  -scheme wallpaper-browser \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data_path" \
  GIT_COMMIT="$git_commit" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

app_path="$archive_path/Products/Applications/wallpaper-browser.app"
if [[ ! -d "$app_path" ]]; then
  echo "Archive did not contain wallpaper-browser.app." >&2
  exit 1
fi

# Remove local Finder/quarantine metadata before creating a redistributable archive.
xattr -cr "$app_path" 2>/dev/null || true
find "$app_path" -name '._*' -type f -delete

# Ad-hoc sign so LaunchServices/Dock treat the bundle as a proper app.
if ! codesign --force --deep --sign - "$app_path" 2>/dev/null; then
  echo "Warning: ad-hoc signing failed; the app will ship unsigned." >&2
else
  echo "Ad-hoc signed: $app_path"
fi

zip_path="$output_dir/WallpaperBrowser-${marketing_version}-universal-unsigned.zip"
rm -f "$zip_path"
(cd "$(dirname "$app_path")" && zip -q -r -X "$zip_path" "$(basename "$app_path")")

echo "Created: $zip_path"
echo "The app carries an ad-hoc signature. macOS may still require Finder > Open on first launch."
