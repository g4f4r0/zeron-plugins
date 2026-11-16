# Desktop

A Linux desktop for agents, shown live in a chat's panel. It runs on the device the chat runs on, and you can watch and click it from any of your devices.

The desktop is display `:1` (Xvfb, 1920x1080) with the Openbox window manager, a wallpaper, and three programs: one [Fortress](https://github.com/tiliondev/fortress) browser, Thunar for files and a terminal. There is no panel, dock or launcher. Right-click the desktop for a menu with Browser, Files and Terminal, or press Ctrl+Alt+B, Ctrl+Alt+F or Ctrl+Alt+T. Agents drive it with Vercel's two tools: [`agent-browser`](https://www.npmjs.com/package/agent-browser) controls Fortress over CDP on `127.0.0.1:9222`, and [`agent-desktop`](https://www.npmjs.com/package/agent-desktop) controls everything else through AT-SPI. [voxl](https://github.com/tembo/voxl) streams the screen, sound and input on `127.0.0.1:6080`, and the plugin's tab is a web view of that stream.

## How it works

- `host/desktop.sh` sets up the desktop as systemd user units: `agent-desktop.target` and one service each for `x`, `session`, `browser` and `stream`. Each service runs one subcommand of the script. `install` writes the units and a random voxl password, stored in `~/.config/agent-desktop/env` with mode 0600, then enables and starts the desktop.
- The session writes Openbox's config from its system defaults each time it starts: one desktop, a dark theme, the menu and keys, and the browser always maximized, so it fits the screen when voxl resizes it to your window. It redraws the wallpaper whenever the screen changes size.
- Closing the browser leaves it closed; its unit restarts it only after a crash. `bash ~/.local/share/agent-desktop/desktop.sh open browser [url]` opens it again with CDP, or opens a new window or the URL in the running one. `open files [dir]` and `open terminal` open the other two. The menu and keys run the same command, and agents should too, because it starts the programs with the desktop's environment.
- `service.luau` runs on every device where the plugin is allowed. It reads the units with `systemctl --user show` and answers `status` (whether each part is running, plus the voxl link) and `start` (`systemctl --user start agent-desktop.target`). The desktop counts as ready without the browser. A window on the same device gets voxl's local link. A window on another device gets the tailnet HTTPS link.
- `init.luau` adds a Desktop row (key D) to an empty panel's home page. The row opens a Desktop tab for the chat's device. The tab shows the stream when the desktop is running, and offers a Start button when it's stopped.
- The tab copies text between your device's clipboard and the desktop's, because a page in Zeron's web view can't use the clipboard reliably. While the desktop shows and Zeron's window is in front, new text you copy on your device goes to the desktop, and text copied on the desktop comes back to your device. It checks when Zeron comes to the front and then every second. Text only; images still go through voxl's own paste.
- The stream runs only while someone can see it. Once the tab has been hidden or closed, or Zeron's window hidden, for about 30 seconds, the tab closes its page and the desktop stops sending. Back sooner, the page is still connected and shows at once; later, it connects again.
- Links open in the desktop's browser. Thunar, the terminal, `xdg-open` and CLIs that read `$BROWSER` all open a link as a tab there. Only the desktop's programs get this, through `~/.local/share/agent-desktop/bin` and `xdg`.

## Set up a device to host the desktop (Ubuntu)

1. Install the programs. Run `sudo apt install xvfb openbox hsetroot x11-xserver-utils thunar xfce4-terminal dbus-x11 at-spi2-core pulseaudio curl`, then `cargo install voxl-server` and `npm i -g agent-browser agent-desktop`. Unpack the latest Fortress Linux release under `~/.local/share/fortress/<version>/`.
2. Keep Chromium's sandbox on under Ubuntu's user-namespace restriction. Copy the profile into place with `sudo cp host/fortress.apparmor /etc/apparmor.d/agent-desktop-fortress`, edit its path if your home isn't `/home/g4f4r0`, then load it with `sudo apparmor_parser -r /etc/apparmor.d/agent-desktop-fortress`.
3. Install Fortress's policy. It hides the "unsupported command-line flag" banner, which Chromium shows because Fortress's launcher turns on Blink features that real Windows and macOS Chrome have. It also blocks the desktop's own stream (`127.0.0.1:6080`, and port 6443 on the tailnet), so the desktop's browser can never open a mirror of itself. Install it with `sudo mkdir -p /etc/chromium/policies/managed && sudo cp host/chromium-policy.json /etc/chromium/policies/managed/agent-desktop.json`.
4. Optionally, put a wallpaper at `~/.config/agent-desktop/wallpaper.jpg`, or point `AGENT_DESKTOP_WALLPAPER` at one. Without one the desktop is a plain dark blue.
5. Install the desktop with `bash ~/.zeron/plugins/desktop/host/desktop.sh install`. The script copies itself to `~/.local/share/agent-desktop/`, and the units run that copy. Then run `loginctl enable-linger $USER` so the desktop keeps running after you log out.
6. To watch the desktop from other devices, publish the stream on the tailnet with `sudo tailscale serve --bg --https=6443 http://127.0.0.1:6080`.
7. Point `agent-browser` at Fortress with `echo '{"cdp": "9222"}' > ~/.agent-browser/config.json`. Agents run `agent-desktop` with `DISPLAY=:1`.

Allow the plugin in Zeron (Settings → Plugins) on the device hosting the desktop and on every device you watch it from. It asks for `commands`, which lets it run `systemctl` as you; its service needs that to read and start the units. It also asks for `clipboard`, for copy and paste between your device and the desktop.

## Overrides

`desktop.sh` reads these environment variables: `AGENT_DESKTOP_DISPLAY` (default `:1`), `AGENT_DESKTOP_SIZE` (`1920x1080`), `AGENT_DESKTOP_PORT` (`6080`), `AGENT_DESKTOP_CDP_PORT` (`9222`), `AGENT_DESKTOP_SERVE_PORT` (`6443`), `AGENT_DESKTOP_HOST` (default: this machine's tailnet name), `AGENT_DESKTOP_FORTRESS` (path to `tilion`), `AGENT_DESKTOP_VOXL` (path to `voxl`), and `AGENT_DESKTOP_WALLPAPER` (default `~/.config/agent-desktop/wallpaper.jpg`).

## Gotchas

- Programs on the desktop run with a system-only PATH. A `bwrap` in `~/.local/bin` gets refused by AppArmor, which breaks GTK's image loaders and crashes Thunar. `desktop.sh open` sets this up, so use it rather than starting the programs yourself.
- The session uses your own D-Bus, not `dbus-run-session`. That way `agent-desktop`, run from an agent's shell, can reach the desktop's accessibility bus. It also means one Thunar and one terminal serve the whole user: a `thunar` started for another display opens its window here.
- Installs from git drop the executable bit, so always run the script with `bash`.
