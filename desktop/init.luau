--!strict
-- Desktop: the agents' desktop (Xvfb + XFCE, Fortress, agent-desktop) on the
-- device a chat runs on, live in that chat's panel. The desktop runs as
-- systemd user units there; voxl streams it, and this tab is a web view of
-- voxl's page. The service (service.luau) reads the units and the sign-in
-- link, and starts the desktop when it's down.
--
-- The panel's empty page gets a Desktop row (key D); the tab draws the
-- stream, or why it can't yet.

local zeron = require("./zeron")("desktop")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")

local KIND = "desktop"

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

zeron.tab(KIND, function(tab: any): Node
	local device = tab.data and tab.data.device
	local id = `desktop-{device or "local"}`
	local state = ui.use_state({ phase = "loading" } :: any)
	-- zgx keeps the page by id across tab switches and reloads.
	local web = (ui :: any).web(id)
	local loaded: string? = nil

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
		state:set({ phase = "error", why = zeron.reason(err) or tostring(err) })
	end
	local function check()
		zeron.service(device):call("status", {}):after(apply, fail)
	end
	local function start()
		state:set({ phase = "starting" })
		zeron.service(device):call("start", {}, { timeout = 60 }):after(apply, fail)
	end

	ui.effect(function()
		local s = state:get()
		if s.phase == "ready" and s.url ~= loaded and s.url ~= web.url then
			loaded = s.url
			web:load(s.url)
		end
	end)
	check()

	local function empty(which: string, action: any?): Node
		return EmptyState {
			icon = "monitor",
			size = "sm",
			title = zeron.t(`{which}.title`),
			body = if which == "starting" then nil else zeron.t(`{which}.body`),
			action = action,
		}
	end
	local retry = { label = zeron.t("retry"), on_click = check }

	return ui.column {
		w_full = true,
		h_full = true,
		ui.switch(function(): string
			return state:get().phase
		end, {
			ready = (ui :: any).webview {
				id = `desktop-view-{id}`,
				label = zeron.s("tab.title"),
				web = web,
				w_full = true,
				grow = 1,
				min_h = 0,
			},
			stopped = empty("stopped", { label = zeron.t("stopped.start"), on_click = start }),
			starting = empty("starting"),
			missing = empty("missing", retry),
			no_url = empty("no_url", retry),
			error = EmptyState {
				icon = "monitor",
				size = "sm",
				title = zeron.t("error.title"),
				body = zeron.t("error.body", {
					why = function(): string
						return state:get().why or ""
					end,
				}),
				action = retry,
			},
			loading = ui.div {},
		}),
	}
end)
