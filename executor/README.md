# Executor

Adds [executor.sh](https://executor.sh) to Zeron as one shared MCP server, `plugin-executor`, that every provider's agents on this device can use. Connect your accounts and tools to Executor once, and Claude Code, Codex and the rest all reach them through it.

## How it works

The manifest's `mcp` entry makes Zeron start `bin/executor-mcp`. That launcher:

1. checks that Node.js is on the PATH, and says so in the log if not (Executor's launcher runs on Node);
2. installs Executor with Bun (`bun install -g executor@beta`) if it's missing, and refreshes it once a day; if Bun is missing too, it says so in the log;
3. if Codex is installed, restores Codex's `codex-code-mode-host` in the background when it's missing (see below);
4. runs `executor mcp`, Executor's own stdio MCP server, which passes each message to the host you're signed in to (Cloud, self-hosted, or the local background server) and renews the sign-in as it goes.

Everything the launcher says goes to stderr; stdout is the MCP protocol.

Environment overrides: `ZERON_EXECUTOR_CHANNEL` (default `beta`), `ZERON_EXECUTOR_MAX_AGE` (seconds between update checks, default 86400).

### The Codex helper

Codex 0.153 and later can't call any MCP tool unless a second binary, `codex-code-mode-host`, sits next to `codex`. Some installers ship only `codex`, and every tool call then fails with "failed to spawn code-mode host … host executable was not found". `bin/restore-codex-host` fixes that: when the file is missing it downloads the matching asset from the same `openai/codex` GitHub release, checks it against the SHA-256 digest GitHub publishes for that asset, and only then installs it beside `codex`. It installs nothing if it can't get a digest or the checksum differs, does nothing when the file is already there, and logs to `~/.local/share/zeron-executor/codex-host.log`. It's the only part of the plugin that touches anything outside Executor, and it never replaces an existing file.

## Requirements (per device)

- [Node.js](https://nodejs.org) and [Bun](https://bun.sh) on the PATH (`~/.bun/bin` and `~/.local/node/bin` are added automatically).
- Allow the plugin in Zeron (Settings → Plugins). It asks for `native`, which lets it run its launcher as you.
- Optional: `executor login` (or `executor login --host <url>` for self-hosted) to use Executor Cloud. Without a sign-in it uses the local background server on `127.0.0.1:4312`.
- Sign-in access: `executor login` lets you choose which apps the sign-in reaches. Everything it reaches is available to every provider's agents.
