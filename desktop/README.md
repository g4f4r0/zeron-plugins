# Desktop

A Linux desktop for agents, shown live in a chat's panel. It runs on the device the chat runs on, and you can watch and click it from any of your devices.

The desktop is display `:1` (Xvfb, 1920x1080) with an XFCE session and one [Fortress](https://github.com/tiliondev/fortress) browser. Agents drive it with Vercel's two tools: [`agent-browser`](https://www.npmjs.com/package/agent-browser) controls Fortress over CDP on `127.0.0.1:9222`, and [`agent-desktop`](https://www.npmjs.com/package/agent-desktop) controls everything else through AT-SPI. [voxl](https://github.com/tembo/voxl) streams the screen, sound and input on `127.0.0.1:6080`, and the plugin's tab is a web view of that stream.

## How it works

- `host/desktop.sh` sets up the desktop as systemd user units: `agent-desktop.target` and one service each for `x`, `session`, `browser` and `stream`. Each service runs one subcommand of the script. `install` writes the units and a random voxl password, stored in `~/.config/agent-desktop/env` with mode 0600, then enables and starts the desktop.
- `service.luau` runs on every device where the plugin is allowed. It reads the units with `systemctl --user show` and answers `status` (whether each part is running, plus the voxl link) and `start` (`systemctl --user start agent-desktop.target`). A window on the same device gets voxl's local link. A window on another device gets the tailnet HTTPS link.
- `init.luau` adds a Desktop row (key D) to an empty panel's home page. The row opens a Desktop tab for the chat's device. The tab shows the stream when the desktop is running, and offers a Start button when it's stopped.

## Set up a device to host the desktop (Ubuntu)

1. Install the programs. Run `sudo apt install xvfb xfce4 xfce4-terminal dbus-x11 at-spi2-core pulseaudio x11-utils`, then `cargo install voxl-server` and `npm i -g agent-browser agent-desktop`. Unpack the latest Fortress Linux release under `~/.local/share/fortress/<version>/`.
2. Keep Chromium's sandbox on under Ubuntu's user-namespace restriction. Copy the profile into place with `sudo cp host/fortress.apparmor /etc/apparmor.d/agent-desktop-fortress`, edit its path if your home isn't `/home/g4f4r0`, then load it with `sudo apparmor_parser -r /etc/apparmor.d/agent-desktop-fortress`.
3. Install the desktop with `bash ~/.zeron/plugins/desktop/host/desktop.sh install`. The script copies itself to `~/.local/share/agent-desktop/`, and the units run that copy. Then run `loginctl enable-linger $USER` so the desktop keeps running after you log out.
4. To watch the desktop from other devices, publish the stream on the tailnet with `sudo tailscale serve --bg --https=6443 http://127.0.0.1:6080`.
5. Point `agent-browser` at Fortress with `echo '{"cdp": "9222"}' > ~/.agent-browser/config.json`. Agents run `agent-desktop` with `DISPLAY=:1`.

Allow the plugin in Zeron (Settings → Plugins) on the device hosting the desktop and on every device you watch it from. It asks for `commands`, which lets it run `systemctl` as you; its service needs that to read and start the units.

## Overrides

`desktop.sh` reads these environment variables: `AGENT_DESKTOP_DISPLAY` (default `:1`), `AGENT_DESKTOP_SIZE` (`1920x1080`), `AGENT_DESKTOP_PORT` (`6080`), `AGENT_DESKTOP_CDP_PORT` (`9222`), `AGENT_DESKTOP_SERVE_PORT` (`6443`), `AGENT_DESKTOP_HOST` (default: this machine's tailnet name), `AGENT_DESKTOP_FORTRESS` (path to `tilion`), and `AGENT_DESKTOP_VOXL` (path to `voxl`).

## Gotchas

- The XFCE session runs with a system-only PATH. A `bwrap` in `~/.local/bin` gets refused by AppArmor, which breaks GTK's image loaders and crashes XFCE.
- The session uses your own D-Bus, not `dbus-run-session`. That way `agent-desktop`, run from an agent's shell, can reach the desktop's accessibility bus.
- Installs from git drop the executable bit, so always run the script with `bash`.
