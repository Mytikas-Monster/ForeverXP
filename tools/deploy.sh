#!/usr/bin/env bash
# Copy the addon into the game's AddOns folder.
#   tools/deploy.sh                 use the default install path
#   WOW_ADDONS=/path tools/deploy.sh
# Only the files the game loads are copied; tests, tools and legacy stay here.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
addons="${WOW_ADDONS:-/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns}"
dest="$addons/ForeverXP"

if [ ! -d "$addons" ]; then
    echo "AddOns folder not found: $addons" >&2
    exit 1
fi

files=(ForeverXP.toc README.md)
while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
        *.lua) files+=("$line") ;;
    esac
done < "$src/ForeverXP.toc"

for f in "${files[@]}"; do
    if [ ! -f "$src/$f" ]; then
        echo "missing source file: $f" >&2
        exit 1
    fi
done

mkdir -p "$dest"
# Files from the old single-file version that the new TOC no longer lists.
rm -f "$dest/ForeverXP.lua" "$dest/README.txt"
for f in "${files[@]}"; do
    cp "$src/$f" "$dest/$f"
done

echo "Deployed ${#files[@]} files to $dest"
ls -la "$dest"
