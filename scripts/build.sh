#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_dir/dist/AI Usage.app"
claude_app_path="${CLAUDE_APP_PATH:-/Applications/Claude.app}"
chatgpt_app_path="${CHATGPT_APP_PATH:-/Applications/ChatGPT.app}"
claude_logo="$claude_app_path/Contents/Resources/TrayIconTemplate@3x.png"
openai_logo="$chatgpt_app_path/Contents/Resources/chatgptTemplate@2x.png"

for asset in "$claude_logo" "$openai_logo"; do
  if [[ ! -f "$asset" ]]; then
    printf 'Missing logo asset: %s\nInstall the Claude and ChatGPT desktop apps, or set CLAUDE_APP_PATH and CHATGPT_APP_PATH.\n' "$asset" >&2
    exit 1
  fi
done

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$repo_dir/Info.plist" "$app_path/Contents/Info.plist"
cp "$claude_logo" "$app_path/Contents/Resources/ClaudeMark.png"
cp "$openai_logo" "$app_path/Contents/Resources/OpenAIMark.png"
if [[ -f "$chatgpt_app_path/Contents/Resources/icon-chatgpt.icns" ]]; then
  cp "$chatgpt_app_path/Contents/Resources/icon-chatgpt.icns" "$app_path/Contents/Resources/AppIcon.icns"
fi

swiftc -parse-as-library -O "$repo_dir/Sources/AIUsage.swift" \
  -framework AppKit -framework SwiftUI -framework Security -framework Network -framework CryptoKit \
  -o "$app_path/Contents/MacOS/CodexUsage"
codesign --force --deep --sign - "$app_path"
printf 'Built %s\n' "$app_path"
