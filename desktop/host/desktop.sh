#!/usr/bin/env bash
# The agents' desktop on this server: display :1 (Xvfb), an Openbox session with
# a wallpaper and nothing else, one Fortress browser with CDP on 127.0.0.1:9222,
# and voxl streaming it on 127.0.0.1:6080. Each part is a systemd user unit
# that runs one subcommand. Right-click the desktop, or press Ctrl+Alt+B, F or T,
# to open the browser, files or a terminal.
#
#   desktop.sh install        write the units and the password, enable, start
#   desktop.sh uninstall      stop and remove the units (the profile stays)
#   desktop.sh open browser [url] | files [dir] | terminal
#                             open one of the three apps on the desktop
#   desktop.sh status         one JSON line: running parts, the sign-in link
#   desktop.sh url            the sign-in link
#   desktop.sh x|session|browser|stream   what each unit runs
set -euo pipefail

DISPLAY_NUM="${AGENT_DESKTOP_DISPLAY:-:1}"
SIZE="${AGENT_DESKTOP_SIZE:-1920x1080}"
PORT="${AGENT_DESKTOP_PORT:-6080}"
CDP_PORT="${AGENT_DESKTOP_CDP_PORT:-9222}"
HOME_DIR="${HOME}"
STATE="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/agent-desktop"
CONF="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/agent-desktop"
UNITS="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/systemd/user"
FORTRESS="${AGENT_DESKTOP_FORTRESS:-$(ls -d "$HOME_DIR"/.local/share/fortress/*/fortress-*/tilion 2>/dev/null | sort -V | tail -1)}"
VOXL="${AGENT_DESKTOP_VOXL:-$HOME_DIR/.cargo/bin/voxl}"
SERVE_PORT="${AGENT_DESKTOP_SERVE_PORT:-6443}"
TAILNET_HOST="${AGENT_DESKTOP_HOST:-$(tailscale status --json 2>/dev/null | grep -m1 '"DNSName"' | sed 's/.*: "\(.*\)\.",*$/\1/')}"
WALLPAPER="${AGENT_DESKTOP_WALLPAPER:-$CONF/wallpaper.jpg}"
BACKGROUND="#1d2330"
PROFILE="$STATE/fortress-profile"
PARTS=(x session browser stream)

export DISPLAY="$DISPLAY_NUM"

# What every program on the desktop runs with. System programs only: GTK's image loaders
# (glycin) run in the system bwrap, which AppArmor allows; a bwrap earlier on PATH
# (~/.local/bin) is refused, and GTK apps crash on their icons. The accessibility bridge
# lets agent-desktop see GTK 3 apps.
desktop_env() {
	export PATH=/usr/local/bin:/usr/bin:/bin
	export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=Openbox GTK_THEME=Adwaita:dark
	export GTK_MODULES=gail:atk-bridge NO_AT_BRIDGE=0
}

# The image scaled to cover the screen, over a plain colour that shows when there's no image
# (hsetroot exits 0 even when it can't read one).
wallpaper() {
	xsetroot -solid "$BACKGROUND"
	if [ -r "$WALLPAPER" ] && command -v hsetroot >/dev/null; then
		hsetroot -cover "$WALLPAPER" >/dev/null 2>&1 || true
	fi
}

screen_size() { xrandr --current 2>/dev/null | sed -n 's/.* current \([0-9]*\) x \([0-9]*\).*/\1x\2/p'; }

# Openbox's own defaults, changed to one desktop, a dark theme, our menu and keys, and the
# browser maximized, so it always fits the screen, also after voxl resizes it.
openbox_config() {
	local ob="$STATE/openbox" base="" d
	local IFS=:
	for d in ${XDG_CONFIG_DIRS:-/etc/xdg}; do
		[ -r "$d/openbox/rc.xml" ] && { base="$d/openbox/rc.xml"; break; }
	done
	unset IFS
	[ -n "$base" ] || { echo "Openbox's rc.xml not found; install openbox" >&2; return 1; }
	mkdir -p "$ob"
	local run="bash $STATE/desktop.sh open"
	cat >"$ob/menu.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Desktop">
    <item label="Browser"><action name="Execute"><command>$run browser</command></action></item>
    <item label="Files"><action name="Execute"><command>$run files</command></action></item>
    <item label="Terminal"><action name="Execute"><command>$run terminal</command></action></item>
  </menu>
</openbox_menu>
EOF
	cat >"$ob/keys.xml" <<EOF
  <keybind key="C-A-b"><action name="Execute"><command>$run browser</command></action></keybind>
  <keybind key="C-A-f"><action name="Execute"><command>$run files</command></action></keybind>
  <keybind key="C-A-t"><action name="Execute"><command>$run terminal</command></action></keybind>
EOF
	cat >"$ob/apps.xml" <<EOF
  <application role="browser"><maximized>yes</maximized></application>
EOF
	sed -e 's|<name>Clearlooks</name>|<name>Onyx</name>|' \
		-e 's|<number>4</number>|<number>1</number>|' \
		-e 's|<size>[89]</size>|<size>11</size>|' \
		-e '\|<file>/var/lib/openbox/debian-menu.xml</file>|d' \
		-e "s|<file>menu.xml</file>|<file>$ob/menu.xml</file>|" \
		-e "\|<chainQuitKey>|r $ob/keys.xml" \
		-e "\|^<applications>|r $ob/apps.xml" \
		"$base" >"$ob/rc.xml"
}

wait_for_display() {
	for _ in $(seq 1 50); do
		xdpyinfo >/dev/null 2>&1 && return 0
		[ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ] && return 0
		sleep 0.2
	done
	echo "display $DISPLAY_NUM did not come up" >&2
	return 1
}

password() { sed -n 's/^VOXL_PASSWORD=//p' "$CONF/env" 2>/dev/null; }

unit() {
	local part="$1" desc="$2" after="$3" restart="$4" extra="${5:-}"
	cat >"$UNITS/agent-desktop-$part.service" <<EOF
[Unit]
Description=Agent desktop: $desc
PartOf=agent-desktop.target
${after:+After=$after
Requires=$after}

[Service]
Type=simple
Environment=PATH=$HOME_DIR/.local/bin:$HOME_DIR/.local/node/bin:$HOME_DIR/.npm-global/bin:$HOME_DIR/.cargo/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$CONF/env
${extra}
ExecStart=/usr/bin/env bash $STATE/desktop.sh $part
Restart=$restart
RestartSec=3

[Install]
WantedBy=agent-desktop.target
EOF
}

case "${1:-}" in
x)
	rm -f "/tmp/.X${DISPLAY_NUM#:}-lock"
	exec Xvfb "$DISPLAY_NUM" -screen 0 "${SIZE}x24" -shmem -nolisten tcp -dpi 96
	;;
session)
	wait_for_display
	# Desktop audio for the stream: a null sink named "output" (voxl reads output.monitor).
	pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes
	pactl list short sinks 2>/dev/null | grep -q $'\toutput\t' ||
		pactl load-module module-null-sink sink_name=output >/dev/null
	desktop_env
	openbox_config
	xsetroot -cursor_name left_ptr
	# The wallpaper again whenever the screen changes size (voxl fits it to the viewer).
	(
		last=""
		while :; do
			size="$(screen_size)"
			if [ -n "$size" ] && [ "$size" != "$last" ]; then
				wallpaper
				last="$size"
			fi
			sleep 2
		done
	) &
	# On the user's own session bus, so agents' shells (agent-desktop) reach this desktop's
	# accessibility bus too; a private bus (dbus-run-session) would hide every app from them.
	exec openbox --config-file "$STATE/openbox/rc.xml"
	;;
browser)
	wait_for_display
	[ -n "$FORTRESS" ] && [ -e "$FORTRESS" ] || { echo "Fortress not found; set AGENT_DESKTOP_FORTRESS" >&2; exit 1; }
	mkdir -p "$PROFILE"
	# No Google sign-in or sync here; "no" keys stop the "Google API keys are missing" banner.
	export GOOGLE_API_KEY=no GOOGLE_DEFAULT_CLIENT_ID=no GOOGLE_DEFAULT_CLIENT_SECRET=no
	exec bash "$FORTRESS" \
		--user-data-dir="$PROFILE" \
		--remote-debugging-address=127.0.0.1 --remote-debugging-port="$CDP_PORT" \
		--force-renderer-accessibility --no-first-run --no-default-browser-check \
		--start-maximized about:blank
	;;
open)
	desktop_env
	case "${2:-}" in
	browser)
		# Closing the last window ends the browser and its unit stays stopped. Starting the unit
		# brings it back with CDP. While it runs, Chrome's own launcher hands a new window (or the
		# URL) to it and exits at once.
		if ! systemctl --user is-active --quiet agent-desktop-browser; then
			systemctl --user start agent-desktop-browser
			[ -n "${3:-}" ] || exit 0
			for _ in $(seq 1 50); do
				curl -fsS -o /dev/null "http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null && break
				sleep 0.2
			done
		fi
		chrome="$(dirname "$FORTRESS")/chrome"
		[ -x "$chrome" ] || chrome="$FORTRESS"
		exec setsid -f "$chrome" --user-data-dir="$PROFILE" ${3:+"$3"} >/dev/null 2>&1
		;;
	files) exec setsid -f thunar "${3:-$HOME_DIR}" >/dev/null 2>&1 ;;
	terminal) exec setsid -f xfce4-terminal --working-directory="$HOME_DIR" >/dev/null 2>&1 ;;
	*)
		echo "usage: desktop.sh open browser [url] | files [dir] | terminal" >&2
		exit 2
		;;
	esac
	;;
stream)
	wait_for_display
	# Reached from other machines only through `tailscale serve` (HTTPS on the tailnet), which
	# sends this machine's tailnet name as the host.
	exec "$VOXL" --addr 127.0.0.1 --port "$PORT" --title "Agent desktop" \
		--enable-resize true --files-root "$HOME_DIR/projects" \
		${TAILNET_HOST:+--allowed-hosts "$TAILNET_HOST"}
	;;
url)
	# The tailnet link when `tailscale serve` publishes the stream, else the local one.
	if [ -n "${TAILNET_HOST:-}" ] && tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
		echo "https://$TAILNET_HOST:$SERVE_PORT/?token=$(password)"
	else
		echo "http://127.0.0.1:$PORT/?token=$(password)"
	fi
	;;
status)
	running=()
	for p in "${PARTS[@]}"; do
		systemctl --user is-active --quiet "agent-desktop-$p" && running+=("\"$p\"")
	done
	printf '{"running":[%s],"parts":%d,"url":"%s","cdp":"http://127.0.0.1:%s"}\n' \
		"$(IFS=,; echo "${running[*]}")" "${#PARTS[@]}" "$(bash "$0" url)" "$CDP_PORT"
	;;
install)
	mkdir -p "$STATE" "$CONF" "$UNITS"
	[ "$(readlink -f "$0")" = "$STATE/desktop.sh" ] || install -m 0755 "$0" "$STATE/desktop.sh"
	if [ ! -s "$CONF/env" ]; then
		umask 077
		printf 'VOXL_PASSWORD=%s\nDISPLAY=%s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" "$DISPLAY_NUM" >"$CONF/env"
	fi
	cat >"$UNITS/agent-desktop.target" <<EOF
[Unit]
Description=Agent desktop: display $DISPLAY_NUM, Openbox, Fortress, voxl on 127.0.0.1:$PORT

[Install]
WantedBy=default.target
EOF
	unit x "display $DISPLAY_NUM (Xvfb)" "" always
	unit session "Openbox session" agent-desktop-x.service always
	# Closing the browser leaves it closed; only a crash brings it back.
	unit browser "Fortress with CDP on 127.0.0.1:$CDP_PORT" agent-desktop-x.service on-failure
	# The sign-in links, where the Zeron plugin reads them (`systemctl --user show -p Environment`).
	local_url="http://127.0.0.1:$PORT/?token=$(password)"
	unit stream "voxl on 127.0.0.1:$PORT" agent-desktop-x.service always \
		"Environment=AGENT_DESKTOP_LOCAL_URL=$local_url AGENT_DESKTOP_URL=${TAILNET_HOST:+https://$TAILNET_HOST:$SERVE_PORT/?token=$(password)}"
	systemctl --user daemon-reload
	systemctl --user enable agent-desktop.target "${PARTS[@]/#/agent-desktop-}" >/dev/null 2>&1
	systemctl --user restart agent-desktop.target "${PARTS[@]/#/agent-desktop-}"
	bash "$0" status
	;;
uninstall)
	systemctl --user disable --now agent-desktop.target "${PARTS[@]/#/agent-desktop-}" >/dev/null 2>&1 || true
	rm -f "$UNITS"/agent-desktop.target "$UNITS"/agent-desktop-*.service
	systemctl --user daemon-reload
	echo '{"running":[]}'
	;;
*)
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
