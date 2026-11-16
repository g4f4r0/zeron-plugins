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
--
-- The clipboard: a page in Zeron's web view can't count on reading or
-- writing this device's clipboard, so the tab moves the text itself
-- (`clipboard`). While the desktop shows and Zeron's window is in front, new
-- text on this device's clipboard goes to the desktop's, and text copied on
-- the desktop comes back here. voxl's socket lives in a worker of the page;
-- the script finds it when the page next talks to it (any input does) and
-- sends the text the way voxl's own paste does (`c,<text>`). voxl only
-- reports the desktop's clipboard when it changes, never on connecting.
--
-- The stream only while someone can see it: a tab hidden, or Zeron's window
-- hidden, for AWAY_S closes its page, and the desktop stops sending.

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
  if (!window.__zeronDesktopClipboard && window.Worker) {
    window.__zeronDesktopClipboard = true;
    const post = Worker.prototype.postMessage;
    let worker = null;
    let pending = null;
    const give = (w, text) => post.call(w, { t: 'send', d: 'c,' + text });
    const adopt = (w) => {
      if (worker === w) return;
      worker = w;
      w.addEventListener('message', (e) => {
        const m = e.data;
        if (m && m.t === 'clip' && typeof m.d === 'string') send({ clip: m.d });
      });
      if (pending !== null) { give(w, pending); pending = null; }
    };
    Worker.prototype.postMessage = function (...args) {
      adopt(this);
      return post.apply(this, args);
    };
    window.__zeronDesktopClip = (text) => {
      if (worker) give(worker, text); else pending = text;
    };
    document.addEventListener('keydown', (e) => {
      if (e.metaKey && !e.altKey && (e.key === 'v' || e.key === 'V') && !e.repeat) send({ paste: true });
    }, true);
  }
})();
]]

-- How often the tab looks at this device's clipboard while it shows the
-- desktop in the window in front (milliseconds). Switching to Zeron looks
-- at once.
local CLIP_MS = 1000

-- A JavaScript string literal for any text.
local function js_string(s: string): string
	local ok, lit = pcall(ui.json.encode, s)
	if ok and type(lit) == "string" then
		return (string.gsub(string.gsub(lit, "\226\128\168", "\\u2028"), "\226\128\169", "\\u2029"))
	end
	local out = string.gsub(s, "[%c\"\\]", function(c: string): string
		return string.format("\\u%04x", string.byte(c))
	end)
	return `"{out}"`
end

-- How long a loaded page has to say how it stands before the tab shows it
-- as it is (a page that can't, as one without the bridge), in ms.
local QUIET_MS = 4000

-- The stream while nobody sees it: zgx keeps a page by id after its tab
-- hides (another tab shows, another chat opens, the tab closes) and while
-- Zeron's window is hidden, and voxl's page goes on streaming there. A page
-- away AWAY_S is closed, so the desktop stops sending; a tab back sooner
-- finds its page still connected. `away` holds each page away, by id: when
-- it went, and whether it's been closed.
local AWAY_S = 30
type Away = { web: any, since: number, closed: boolean }
local away: { [string]: Away } = {}
local sweeping = pcall(zeron.every, AWAY_S, function()
	local now = os.time()
	for id, a in away do
		if now - a.since >= AWAY_S then
			away[id] = nil
			a.closed = true
			pcall(function()
				a.web:close()
			end)
		end
	end
end)
-- A page going away: kept for AWAY_S, or closed now if nothing would close
-- it later.
local function leave(id: string, web: any): Away
	local a = away[id] or { web = web, since = os.time(), closed = false }
	if sweeping then
		away[id] = a
	else
		a.closed = true
		pcall(function()
			web:close()
		end)
	end
	return a
end

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
	-- zgx keeps the page by id across tab switches and reloads. One back
	-- within AWAY_S is still connected, and is taken as it is.
	local web = (ui :: any).web(id)
	local back = away[id]
	away[id] = nil
	local kept = back ~= nil and not back.closed
	-- The page away while Zeron's window is hidden, as if its tab were.
	local hiding: Away? = nil
	local finished: () -> ()
	local loaded: string? = nil
	local said = 0
	-- The text both clipboards hold, as far as the tab knows; nil when the
	-- page hasn't been given any since it loaded or reconnected.
	local held: string? = nil

	-- This device's clipboard to the desktop's, when it has new text.
	local function clip_give()
		if not zeron.window(true).active then
			return
		end
		local ok, text = pcall(ui.clipboard.read)
		if not ok or type(text) ~= "string" or text == "" or text == held then
			return
		end
		held = text
		pcall(function()
			web:run(`window.__zeronDesktopClip && window.__zeronDesktopClip({js_string(text)});`)
		end)
	end
	-- The desktop's clipboard to this device's: only while Zeron's window is
	-- in front, so what an agent copies while you work elsewhere stays there.
	local function clip_take(text: any)
		if type(text) ~= "string" or text == "" or text == held or not zeron.window(true).active then
			return
		end
		held = text
		pcall(ui.clipboard.write, text)
	end

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
		kept = false
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
			if kept and s.url == web.url then
				-- Still connected: asked how it stands, once its view is there.
				kept = false
				ui.after(0, finished)
			elseif s.url == web.url then
				web:reload()
			else
				web:load(s.url)
			end
		end
	end)
	check()

	-- Zeron's window hidden: the page away, closed after AWAY_S. Shown
	-- again: kept if it's still there, else made and loaded anew.
	ui.effect(function()
		if not zeron.window().shown then
			if not hiding then
				hiding = leave(id, web)
			end
		elseif hiding then
			local h = hiding
			hiding = nil
			if h.closed then
				web = (ui :: any).web(id)
				again()
			elseif away[id] == h then
				away[id] = nil
			end
		end
	end)
	-- The tab hidden or closed: its page away (unless already closed).
	pcall(ui.on_cleanup, function()
		if not (hiding and hiding.closed) then
			leave(id, web)
		end
	end)

	-- Once a load has finished: ask the page how it stands, and show it as
	-- it is if it doesn't say.
	function finished()
		said += 1
		local mine = said
		held = nil
		pcall(function()
			web:run(PAGE_JS)
		end)
		clip_give()
		ui.after(QUIET_MS, function()
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
		-- The clipboard while the desktop shows: at once when Zeron's window
		-- comes to the front, and every CLIP_MS while it stays there.
		ui.effect(function()
			if zeron.window().active then
				clip_give()
			end
		end)
		ui.every(CLIP_MS, clip_give)
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
					-- Connected again: the desktop may have missed text meanwhile.
					if value.state == "connected" and page:peek().state ~= "connected" then
						held = nil
						clip_give()
					end
					page:set({ state = value.state, text = value.text })
				elseif value.clip ~= nil then
					clip_take(value.clip)
				elseif value.paste then
					clip_give()
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
