#!/bin/sh
set -eu

app_bundle=${1:?usage: prepare-sparkle-release.sh APP_BUNDLE OUTPUT_DIRECTORY KEY_ACCOUNT}
output_directory=${2:?usage: prepare-sparkle-release.sh APP_BUNDLE OUTPUT_DIRECTORY KEY_ACCOUNT}
key_account=${3:?usage: prepare-sparkle-release.sh APP_BUNDLE OUTPUT_DIRECTORY KEY_ACCOUNT}

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sparkle_tools="$project_directory/.build/artifacts/sparkle/Sparkle/bin"
plist="$app_bundle/Contents/Info.plist"

if [ ! -x "$sparkle_tools/sign_update" ]; then
    echo "Sparkle sign_update not found; run swift package resolve first." >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
archive_name="CloudCodex-$(printf '%s' "$version" | tr '.' '-').zip"

mkdir -p "$output_directory"
archive="$output_directory/$archive_name"
metadata="$output_directory/CloudCodex-$(printf '%s' "$version" | tr '.' '-').sparkle.json"
rm -f "$archive" "$archive.sha256" "$metadata"

ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"
sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
signature_output=$("$sparkle_tools/sign_update" --account "$key_account" "$archive")
signature=$(printf '%s\n' "$signature_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
length=$(printf '%s\n' "$signature_output" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')

if [ -z "$signature" ] || [ -z "$length" ]; then
    echo "Sparkle did not return an EdDSA signature and archive length." >&2
    exit 1
fi

printf '%s  %s\n' "$sha256" "$archive_name" > "$archive.sha256"
printf '{\n  "latestVersion": "%s",\n  "latestBuild": "%s",\n  "downloadSha256": "%s",\n  "downloadLength": %s,\n  "downloadEdSignature": "%s",\n  "archiveName": "%s"\n}\n' \
    "$version" "$build" "$sha256" "$length" "$signature" "$archive_name" > "$metadata"

echo "Sparkle release archive: $archive"
echo "Sparkle release metadata: $metadata"
