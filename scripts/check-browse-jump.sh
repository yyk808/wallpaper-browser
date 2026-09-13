#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/browse-jump-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
# The test supplies a dummy credential store; no real keychain or network access.
swiftc -parse-as-library -swift-version 5 \
 "$project_root/wallpaper-browser/Models/WorkshopItem.swift" \
 "$project_root/wallpaper-browser/Models/WorkshopDiscovery.swift" \
 "$project_root/wallpaper-browser/Services/WorkshopAPIClient.swift" \
 "$project_root/wallpaper-browser/ViewModels/BrowseViewModel.swift" \
 "$project_root/Tests/BrowseJumpChecks.swift" -o "$check_dir/checks"
"$check_dir/checks"
