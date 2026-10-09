# AI Usage

A compact macOS menu bar app showing **remaining** usage in three rows:

1. Claude 5-hour
2. Claude weekly
3. Codex weekly

The first two rows use the Claude logo and color; the third uses the OpenAI logo and color. Each row can include a short usage bar. Click the indicator to see reset times, refresh, toggle the bars, control launch at login, or open Claude and Codex. Codex refreshes every minute; Claude refreshes every five minutes. A brief Claude refresh failure keeps the last successful reading (dimmed and marked stale) for up to an hour.

## Requirements

- macOS 13 or newer and the Xcode command line tools (`xcode-select --install`)
- Claude Code signed in to a Claude subscription
- Codex CLI signed in to a ChatGPT account
- Claude and ChatGPT desktop apps installed to supply their logo images during the build

## Build

```sh
./scripts/build.sh
open 'dist/AI Usage.app'
```

The app is built at `dist/AI Usage.app` and signed locally with an ad hoc signature. You can copy it to `/Applications`. Launch at login is enabled from the app's popup. To use nonstandard desktop app locations, set `CLAUDE_APP_PATH` and `CHATGPT_APP_PATH` before building.

## How it reads usage

- Codex: starts the locally installed `codex app-server` and requests account rate limits.
- Claude: requests `https://api.anthropic.com/api/oauth/usage` with the app's own Claude sign-in ("Sign in to Claude" in the popup), stored in its own Keychain item and refreshed by the app. Until you sign in, it borrows a signed-in Claude Code CLI's access token read-only; it never refreshes or rewrites the CLI's credential, because refresh tokens rotate and sharing one logs the CLI out.

The Claude usage endpoint is not a documented public API and could change. This is an unofficial project and is not affiliated with Anthropic or OpenAI.

## Assets and license

The source code is MIT licensed. The Claude and OpenAI logos are copied at build time from the locally installed official desktop apps and are **not** included in this repository or covered by the MIT license. The brands and logos belong to their respective owners.
