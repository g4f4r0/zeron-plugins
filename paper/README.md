# Paper

[Paper](https://paper.design) in Zeron. A chat's panel lists the project's Paper designs and shows the canvas live, so you can work in it beside the agent. Agents reach Paper through Paper's own MCP server, set up in each harness with its own sign-in, so Paper works the same inside Zeron and out of it.

## Paper's MCP in each harness

Each harness adds `https://mcp.paper.design/` once and signs in once on each device:

| Harness | Set up | Sign in |
| --- | --- | --- |
| Claude Code | `claude mcp add --transport http --scope user paper https://mcp.paper.design/` | `claude mcp login paper` |
| Codex | `codex mcp add paper --url https://mcp.paper.design/` (signs in as it adds) | `codex mcp login paper` |
| Pi | `pi mcp add paper --url https://mcp.paper.design/` | `pi mcp login paper` |

Sign-in opens Paper's approval page and returns to a `localhost` address on the device. On a device you reach over SSH, use `claude mcp login --no-browser paper` or `codex mcp login --no-browser paper`, approve the page in any browser, and paste the address it lands on back into the terminal. Pi waits on `127.0.0.1`, so sign in to Pi on a device with a browser, or forward its port.

## The panel

An empty panel has one Paper row, and P opens it, as D opens Desktop. The Paper tab lists the designs in `paper.json`, New design under them, and then the agents on the chat's device: Claude Code, Codex and Pi, whichever are installed, each marked Ready, Sign in, Set up or Not working. Choosing one that isn't ready copies the command that sets it up or signs it in, to run in a terminal on that device. The refresh button by the heading checks again.

A design opens live in the tab, with a back arrow to the list.

## Linked designs

A project links its Paper files in `paper.json` at its root:

```json
{
  "files": [
    { "name": "Landing page", "url": "https://app.paper.design/file/..." }
  ]
}
```

A worktree without its own `paper.json` uses its project's. Only `https://app.paper.design/` links are shown.

New design opens Paper's home in the tab. The first file you make or open there is added to the checkout's `paper.json` as `https://app.paper.design/file/<id>`, named after its page title. A worktree with no `paper.json` of its own gets one, starting from its project's list. A file already linked isn't added twice, and a `paper.json` that isn't valid JSON is left alone.

## How it works

- `service.luau` runs on each device where the plugin is allowed. It reads `paper.json` and writes it when New design links a file. It asks each harness where Paper stands with read-only commands: `claude mcp get paper`, `codex mcp list --json` and `pi mcp list --json`. It never adds a server or signs in, because Zeron runs a plugin's programs to the end and can't hand one a sign-in that's still waiting.
- `init.luau` draws the tab with Zeron's own pieces: the panel home's rows and headings, each harness's own mark and a state badge, Zeron's empty state for errors, and Zeron's spinning ring while anything loads (with the engine stepping its clock, so it turns). Paper's mark (`icon.svg`) shows in Settings → Plugins and on the panel's Paper row; the tab itself uses Zeron's palette glyph, since tabs take only Zeron's own glyphs. The view follows Zeron's browser tab, with a 40-point bar and the offline or failed state over the page, with Try again and Dismiss.
- The canvas's web view has its own sign-in to Paper, made by you in the page.

## Permissions

The plugin asks for these:

- `service`, for reading `paper.json` and each harness's state on the chat's device.
- `ui.add`, `panel.tabs` and `web`, for the panel and the canvas.
- `sessions.read` and `files.read`, for the chat's checkout and project.
- `commands`, limited to `cat` and `tee` for `paper.json`, and `claude`, `codex` and `pi` for the read-only status commands above.
- `clipboard`, for copying a set-up or sign-in command.
