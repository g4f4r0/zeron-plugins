# Paper

[Paper](https://paper.design) in Zeron. The canvas shows live in a chat's panel, and every agent, Pi included, reaches Paper's cloud MCP server through two tools. Executor isn't involved, and Paper's tools aren't added to any prompt.

## Tools

- `list_tools` returns Paper's own `tools/list`, with each tool's input schema and the instructions Paper's server gives.
- `call_tool` takes `{ name, arguments }`, sends Paper's `tools/call`, and returns Paper's result unchanged, except images. A tool's result reaches agents as text, so each image (a screenshot) is saved to `/tmp/paper-<time>-<n>.<ext>` and its block says where, for the agent to open. If saving fails, the image stays as Paper sent it, in base64.

Paper's tools pass through as they are, so nothing is renamed, dropped or added. An agent lists them once, then calls the ones it needs.

## Linked designs

A project links its Paper files in `paper.json` at its root:

```json
{
  "files": [
    { "name": "Landing page", "url": "https://app.paper.design/file/..." }
  ]
}
```

An empty panel has one Paper row, and P opens it, as D opens Desktop. The Paper tab lists the designs in `paper.json`, and New design under them. Each design opens in a tab of its own with Paper's panels folded (Paper's `?minimal`), and closing that tab is the way back. A worktree without its own `paper.json` uses its project's. Only `https://app.paper.design/` links are shown.

New design asks Paper for a new file (its `create_file`, through the device's sign-in), adds it to the checkout's `paper.json` as `https://app.paper.design/file/<id>`, and opens it. A worktree with no `paper.json` of its own gets one, starting from its project's list. A file already linked isn't added twice, and a `paper.json` that isn't valid JSON is left alone.

Nothing in the tab asks to be reloaded. The list reads `paper.json` again every few seconds, so a design an agent links shows by itself, and a design that can't load, or a device that can't be reached, is tried again until it can.

## How it works

- `service.luau` runs on each device where the plugin is allowed. It holds that device's Paper sign-in and answers both tools, even with no window open.
- Sign-in uses OAuth's device flow at `login.paper.design`. The service registers itself once as the public client "Zeron Paper". Access tokens last minutes and each refresh token works only once, so the service refreshes one at a time and stores each new token.
- Paper's MCP is streamable HTTP at `https://mcp.paper.design/`. The service opens a session, keeps its id, and passes requests through. On a 401 it refreshes and retries. On a 404 or 400 it opens a new session. Replies may be JSON or an event stream.
- When agents aren't signed in, a tool call fails with the link and code to approve. The tab opens on a Sign in page instead of the list. Sign in opens Paper's approval page where Zeron opens links (Settings → Links), usually the default browser, and the tab shows the code with Open the page again and Cancel until it's approved. Then the list shows.
- `init.luau` draws the tabs with Zeron's own pieces: the panel home's rows and heading for the list, Zeron's empty state for signed out, no designs and errors, and Zeron's spinning ring while anything loads (with the engine stepping its clock, so it turns). Paper's mark (`icon.svg`) shows in Settings → Plugins and on the panel's Paper row; the tabs themselves use Zeron's palette glyph, since tabs take only Zeron's own glyphs. A design's tab is the page alone, with no bar, and the offline or failed state over it while it can't load.

## Permissions

The plugin asks for these:

- `network`, limited to `mcp.paper.design` and `login.paper.design`.
- `tools` and `service`, for the two agent tools.
- `ui.add`, `panel.tabs` and `web`, for the panel and the canvas.
- `links.open`, for opening Paper's sign-in page.
- `sessions.read`, `files.read` and `commands`, limited to `cat` and `tee`, for reading and writing `paper.json`. Only the chat's `paper.json` is written, and only when New design links a file.
- `commands` also allows `openssl`, which writes Paper's images to files (`openssl base64 -d -A -out <file>`, the base64 on stdin).

## Sign-in per device

Each device keeps its own sign-in in the service's store, so agents on another device sign in there once.

The canvas is a web page with its own cookies, kept between runs, so Paper's site asks the person to log in once in the panel too. The agents' sign-in is a token for Paper's MCP server alone and can't sign a web page in.

## Outside Zeron

A harness used on its own can reach Paper's MCP directly. Don't add it to a harness you also use in Zeron, or agents there see Paper twice.

| Harness | Set up | Sign in |
| --- | --- | --- |
| Claude Code | `claude mcp add --transport http --scope user paper https://mcp.paper.design/` | `claude mcp login paper` |
| Codex | `codex mcp add paper --url https://mcp.paper.design/` (signs in as it adds) | `codex mcp login paper` |
| Pi | `pi mcp add paper --url https://mcp.paper.design/` | `pi mcp login paper` |

Each sign-in returns to a `localhost` address on the device, so over SSH use `--no-browser` (Claude Code and Codex) and paste the address back.
