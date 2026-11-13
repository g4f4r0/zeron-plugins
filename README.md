# zeron-plugins

Source and history for my Zeron plugins. One folder per plugin, each exactly as Zeron signs it.

| Plugin | What it does |
|---|---|
| [`executor`](executor/) | Adds the [executor.sh](https://executor.sh) MCP gateway to Zeron as one shared MCP server for every provider. |

## How this repo relates to Zeron

Zeron runs plugins from `~/.zeron/plugins/<id>/`, re-signs them on every save, and refuses plugins that contain symlinks. So that folder stays the working copy and **this repo holds copies of it**:

```sh
./sync executor      # copy the live plugin into the repo
git diff             # review
git commit
```

Zeron's signature (`signature` in each `zeron-plugin.json`) changes whenever a file does, so a commit normally includes that block. That is expected.

## Versions

Bump `version` in the plugin's `zeron-plugin.json` before a release, run `./sync`, commit, and tag `<id>-v<version>` (for example `executor-v0.1.0`).

To package one: `export_plugin` in Zeron (or `zeron plugin export <id>`) writes a signed `.zeron-plugin` file to `~/.zeron/plugin-exports/`. A later export of the same version replaces the earlier file, which is why releases are tagged here.

## Installing from this repo

On another device, `install_plugin` accepts a git repository and a folder, for example `folder: executor`. It still waits for the person to allow it in Zeron.
