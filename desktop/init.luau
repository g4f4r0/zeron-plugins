--!strict
-- Desktop: the agents' desktop (Xvfb + Openbox, Fortress, agent-desktop) on
-- the device a chat runs on, live in that chat's panel. The desktop runs as
-- systemd user units there; voxl streams it, and this tab is a web view of
-- voxl's page. The service (service.luau) reads the units and the sign-in
-- link, and starts the desktop when it's down.
--
-- The panel's empty page gets a Desktop row (key D); the tab draws the
-- stream, or why it can't yet, as Zeron's own panel tabs do: an empty state
-- filling the tab, centred. voxl's page says how its connection stands in
-- words of its own ("Connecting…", "Reconnecting…"); a script run in it
-- hides those and tells the tab instead (`window.zgx.postMessage`), which
-- draws them over the page in Zeron's way.

local zeron = require("./zeron")("desktop")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")
local Progress = require("@ds/progress")

local KIND = "desktop"
local MESSAGE = "zeron.desktop"

-- Run in voxl's page once it has loaded. Only with Zeron's bridge there: the
-- page's own words go (#status, still kept up to date by voxl) and what they
-- say comes to the tab, now and whenever they change. A page without
-- #status is voxl refusing the link (401).
local PAGE_JS = [[
(() => {
  const bridge = window.zgx && window.zgx.postMessage;
  if (!bridge) return;
  const send = (m) => window.zgx.postMessage(Object.assign({ kind: ']] .. MESSAGE .. [[' }, m));
  const status = document.getElementById('status');
  if (!status) { send({ state: 'denied' }); return; }
  if (!window.__zeronDesktop) {
    window.__zeronDesktop = true;
    const style = document.createElement('style');
    style.textContent = '#status { visibility: hidden !important; }';
    document.head.appendChild(style);
    new MutationObserver(() => window.__zeronDesktopSay()).observe(status, {
      attributes: true, childList: true, characterData: true, subtree: true,
    });
  }
  window.__zeronDesktopSay = () => {
    const shown = status.style.display !== 'none';
    const text = (status.textContent || '').trim();
    let state = 'connected';
    if (shown) {
      if (text === 'Connecting…') state = 'connecting';
      else if (text === 'Reconnecting…') state = 'reconnecting';
      else state = 'unsupported';
    }
    send({ state, text });
  };
  window.__zeronDesktopSay();
})();
]]

-- How long a loaded page has to say how it stands before the tab shows it
-- as it is (a page that can't, as one without the bridge).
local QUIET_S = 4

-- A service call's reason, as the tab says it.
local REASONS = {
	offline = true,
	not_approved = true,
	not_installed = true,
	off = true,
	version_mismatch = true,
	timeout = true,
}

local function open_tab(panel: any, session: any)
	panel.open_tab {
		kind = KIND,
		title = zeron.s("tab.title"),
		icon = "monitor",
		data = { key = `desktop-{session.device or "local"}`, device = session.device },
	}
end

zeron.place {
	at = "hook:panel.empty",
	after = function(): Node
		local session = zeron.context("session")
		local panel = zeron.context("panel")
		if not session or not panel then
			return ui.div {}
		end
		-- The home's letter D, as Git takes C and H (`panel_key`: { key, n }).
		local key = zeron.live("panel_key")
		local now = key()
		local seen = if type(now) == "table" then now.n else nil
		ui.effect(function()
			local k = key()
			if type(k) ~= "table" or k.n == seen then
				return
			end
			seen = k.n
			if string.upper(tostring(k.key or "")) == "D" then
				ui.after(0, function()
					open_tab(panel, session)
				end)
			end
		end)
		return PanelHome.Choice {
			id = "desktop-open",
			icon = "monitor" :: any,
			label = zeron.t("row.label") :: any,
			key = "D",
			on_click = function()
				open_tab(panel, session)
			end,
		}
	end,
}

-- Work going on: a ring alone, centred in the tab (its words for screen
-- readers only).
local function working(label: any): Node
	return ui.column {
		w_full = true,
		grow = 1,
		min_h = 0,
		items = "center",
		justify = "center",
		color = "$text.secondary",
		Progress.ProgressRing { size = 16, tone = "neutral", label = label },
	}
end

zeron.tab(KIND, function(tab: any): Node
	local device = tab.data and tab.data.device
	local id = `desktop-{device or "local"}`
	local state = ui.use_state({ phase = "loading" } :: any)
	-- How voxl's page says it stands: "waiting" until it does.
	local page = ui.use_state({ state = "waiting" } :: any)
	-- zgx keeps the page by id across tab switches and reloads.
	local web = (ui :: any).web(id)
	local loaded: string? = nil
	local said = 0

	local function apply(s: any)
		if not s.installed then
			state:set({ phase = "missing" })
		elseif not s.ready then
			state:set({ phase = "stopped" })
		elseif not s.url then
			state:set({ phase = "no_url" })
		else
			state:set({ phase = "ready", url = s.url })
		end
	end
	local function fail(err: any)
		local why = zeron.reason(err)
		state:set({ phase = "error", why = if REASONS[why] then why else "failed" })
	end
	local function check()
		zeron.service(device):call("status", {}):after(apply, fail)
	end
	local function start()
		state:set({ phase = "starting" })
		zeron.service(device):call("start", {}, { timeout = 60 }):after(apply, fail)
	end
	-- Again from the start: the link asked for anew, and the page loaded
	-- again with it.
	local function again()
		loaded = nil
		page:set({ state = "waiting" })
		state:set({ phase = "loading" })
		check()
	end

	ui.effect(function()
		local s = state:get()
		if s.phase ~= "ready" then
			return
		end
		if s.url ~= loaded then
			loaded = s.url
			page:set({ state = "waiting" })
			if s.url == web.url then
				web:reload()
			else
				web:load(s.url)
			end
		end
	end)
	check()

	-- Once a load has finished: ask the page how it stands, and show it as
	-- it is if it doesn't say.
	local function finished()
		said += 1
		local mine = said
		pcall(function()
			web:run(PAGE_JS)
		end)
		ui.after(QUIET_S, function()
			if mine == said and page:peek().state == "waiting" then
				page:set({ state = "quiet" })
			end
		end)
	end

	local function empty(which: string, action: any?): Node
		return EmptyState {
			icon = "monitor",
			size = "sm",
			fill = true,
			title = zeron.t(`{which}.title`),
			body = zeron.t(`{which}.body`),
			action = action,
		}
	end
	local retry = { label = zeron.t("retry"), on_click = check }

	-- Over the page: what it can't show yet, in Zeron's words.
	local function over(): string
		local e = web.error
		local p = page:get().state
		if p == "denied" then
			return "denied"
		elseif type(e) == "string" and e ~= "" then
			return "failed"
		elseif p == "unsupported" then
			return "unsupported"
		elseif p == "reconnecting" then
			return "reconnecting"
		elseif p == "connected" or p == "quiet" then
			return "none"
		end
		return "connecting"
	end

	local function view(): Node
		return ui.column {
		relative = true,
		w_full = true,
		grow = 1,
		min_h = 0,
		(ui :: any).webview {
			id = `desktop-view-{id}`,
			label = zeron.s("tab.title"),
			web = web,
			w_full = true,
			grow = 1,
			min_h = 0,
			on_message = function(value: any, _origin: string, main_frame: boolean)
				if not main_frame or type(value) ~= "table" or value.kind ~= MESSAGE then
					return
				end
				if type(value.state) == "string" then
					page:set({ state = value.state, text = value.text })
				end
			end,
			on_navigate = function(e: any)
				if type(e) ~= "table" then
					return
				end
				if e.kind == "started" then
					said += 1
					page:set({ state = "waiting" })
				elseif e.kind == "finished" then
					finished()
				end
			end,
		},
		ui.show(function(): boolean
			return over() ~= "none"
		end, ui.column {
			absolute = true,
			left = 0,
			right = 0,
			top = 0,
			bottom = 0,
			bg = "$background",
			ui.presence(over, function(which: string): Node
				if which == "failed" then
					return EmptyState {
						icon = "danger-triangle",
						size = "sm",
						fill = true,
						title = zeron.t("failed.title"),
						body = function(): string
							return web.error or ""
						end,
						action = { label = zeron.t("retry"), on_click = again },
					}
				elseif which == "denied" then
					return EmptyState {
						icon = "danger-triangle",
						size = "sm",
						fill = true,
						title = zeron.t("denied.title"),
						body = zeron.t("denied.body"),
						action = { label = zeron.t("retry"), on_click = again },
					}
				elseif which == "unsupported" then
					return EmptyState {
						icon = "danger-triangle",
						size = "sm",
						fill = true,
						title = zeron.t("unsupported.title"),
						body = function(): string
							return page:get().text or ""
						end,
					}
				elseif which == "reconnecting" then
					return working(zeron.t("reconnecting.title"))
				end
				return working(zeron.t("connecting.title"))
			end, { w_full = true, grow = 1, min_h = 0 }),
		}),
		}
	end

	return ui.column {
		w_full = true,
		grow = 1,
		min_h = 0,
		ui.presence(function(): string
			local s = state:get()
			return if s.phase == "error" then `error.{s.why}` else s.phase
		end, function(which: string): Node
			if which == "ready" then
				return view()
			elseif which == "loading" then
				return ui.column { w_full = true, grow = 1 }
			elseif which == "starting" then
				return working(zeron.t("starting.title"))
			elseif which == "stopped" then
				return empty("stopped", { label = zeron.t("stopped.start"), on_click = start })
			elseif which == "missing" or which == "no_url" then
				return empty(which, retry)
			end
			local why = string.sub(which, 7)
			return EmptyState {
				icon = if why == "offline" then "wifi-off" else "danger-triangle",
				size = "sm",
				fill = true,
				title = zeron.t(`error.{why}.title`),
				body = zeron.t(`error.{why}.body`),
				action = retry,
			}
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end)
