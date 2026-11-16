# zeron-plugins

My Zeron plugins, one folder per plugin, tagged per version (`<id>-v<version>`).

| Plugin | What it does |
|---|---|
| [`executor`](executor/) | Adds the [executor.sh](https://executor.sh) MCP gateway to Zeron as one shared MCP server for every provider. |
| [`desktop`](desktop/) | A Linux desktop for agents, live in the chat's panel. |

## Install

```
install_plugin  url: g4f4r0/zeron-plugins  folder: executor   # or desktop
```

Then allow it in Settings → Plugins. Later versions show up there as an update.

## Release a new version

Zeron only re-signs plugins it lists as *yours*, and one installed from GitHub isn't. So edit a local copy, then reinstall.

1. Move the installed plugin out: `mv ~/.zeron/plugins/<id> /tmp/<id>-old`
2. Recreate it as yours: `create_plugin` with the same id and permissions.
3. Copy everything except `zeron-plugin.json` from this repo: `cp -a <id>/. ~/.zeron/plugins/<id>/` (then restore the new manifest's own fields by editing it in place; each save is re-signed).
4. Make the change and bump `version`. Check `plugin_status` isn't `tampered`.
5. `./sync <id>`, commit, `git tag -a <id>-v<version> -m ...`, `git push --follow-tags`.
6. Move the local copy out, `install_plugin` from the repo, allow it in Settings.

## Gotchas

- Installs from git or a package **drop the executable bit**. Start scripts with `bash`, never as `./script`.
- A plugin installed from here can't be edited in place: Zeron marks it `tampered`.
- `./sync` copies `~/.zeron/plugins/<id>` into this repo (Zeron rejects symlinks).
