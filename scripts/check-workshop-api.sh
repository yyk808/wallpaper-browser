#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/workshop-api-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  "$project_root/wallpaper-browser/Models/WorkshopItem.swift" \
  "$project_root/wallpaper-browser/Models/WorkshopDiscovery.swift" \
  "$project_root/wallpaper-browser/Models/FavoriteLibrary.swift" \
  "$project_root/wallpaper-browser/Services/WorkshopDownloadRecovery.swift" \
  "$project_root/wallpaper-browser/Services/VideoPlaybackCompatibility.swift" \
  "$project_root/wallpaper-browser/Services/VideoExtractor.swift" \
  "$project_root/wallpaper-browser/Services/CredentialStore.swift" \
  "$project_root/wallpaper-browser/Services/WorkshopAPIClient.swift" \
  "$project_root/Tests/WorkshopAPIChecks.swift" \
  -o "$check_dir/checks"
if [[ "${1:-}" == "--live" ]]; then
  security find-generic-password -s neon.wallpaper-browser -a steam-web-api-key -w | "$check_dir/checks" --live
else
  "$check_dir/checks" "$@"
fi
