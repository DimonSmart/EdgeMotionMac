#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 MAJOR.MINOR.PATCH SHA256 OUTPUT_CASK" >&2
  exit 2
fi

version="$1"
sha="$2"
output="$3"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid Cask version: $version" >&2
  exit 2
fi
if [[ ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Invalid SHA256: $sha" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
mkdir -p "$(dirname "$output")"
sed -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256@/$sha/g" \
    eng/packaging/edgemotion.rb.in > "$output"
ruby -c "$output"
