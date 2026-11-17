--!strict
-- Paper: the chat's Paper designs, live in its panel. Agents reach Paper
-- through the two tools the service answers (list_tools and
-- call_tool); this window shows the canvas they work on.
--
-- The panel's empty page gets one Paper row (key P), as Desktop's. Its tab
-- first asks whether agents on the chat's device are signed in to Paper:
-- while they aren't, it says so as an empty page with Sign in. Sign in
-- opens Paper's approval page where links open (Settings → Links), and the
-- tab shows the code until it's approved. Signed in, it lists the designs the
-- checkout links in its paper.json, drawn as the panel's home draws rows,
-- and New design, which makes a file in Paper and links it. Each design
-- opens live in a tab of its own, with Paper's panels folded (`minimal`);
-- closing it is the way back.
--
-- Nothing asks to be reloaded: the list reads paper.json again now and then,
-- and what can't be reached is tried again by itself. A design is drawn as
-- Zeron's own browser tab draws a page: a ring while it first loads, and
-- what went wrong over it while it can't.

local zeron = require("./zeron")("paper")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")
local Button = require("@ds/button")

local KIND = "canvas"
local HOME = "https://app.paper.design/"

-- Paper's mark, as icon.svg draws it: in the text's colour, inset as
-- Zeron's own glyphs are in their 24 units.
local MARK = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="-3 -3 27 27"><path d="M3 0H21V13H13V3H3ZM0 3H3V13H13V21H0Z" fill="currentColor"/></svg>]]
local function mark(size: number): Node
	return ui.svg { code = MARK, w = size, h = size, shrink = 0, tint = "currentColor", aria_hidden = true }
end

-- Zeron's spinning ring (ds/progress's arc, the same motion), with the
-- engine stepping its time: ProgressRing doesn't ask for that, so it holds
-- its first frame. A clocked shader drops theme tokens, so its ink is the
-- theme's colour, made again as the theme changes.
local ARC = [[
fn zp_arc(d:vec2<f32>,R:f32,c:f32,ha:f32,hw:f32)->f32 {
 var th=degrees(atan2(d.x,-d.y));
 var da=th-c; da=da-360.*round(da/360.);
 if abs(da)<=ha { return abs(length(d)-R)-hw; }
 let e=radians(c+sign(da)*ha);
 return length(d-vec2(sin(e),-cos(e))*R)-hw;
}
fn fill(input:FillInput)->vec4<f32> {
 let ink=input.params[0];
 let q=input.params[1];
 let hw=q.z*.5;
 let d=input.p-input.size*.5;
 let R=min(input.size.x,input.size.y)*.5-hw;
 let groove=clamp(.5-(abs(length(d)-R)-hw)*input.scale,0.,1.)*q.w;
 let t=input.time;
 let len=30.+240.*(.5-.5*cos(t*2.4));
 let c=t*300.+len*.5;
 let ha=len*.5;
 let arc=clamp(.5-zp_arc(d,R,c,ha,hw)*input.scale,0.,1.);
 return vec4(ink.rgb,ink.a*max(arc,groove));
}
]]
local SPIN = ui.shader(ARC, { fps = 60 })
local function ring(size: number, label: string): Node
	local stroke = math.max(1.5, size / 8)
	local theme = (ui :: any).theme
	return ui.presence(function(): string
		return if theme and theme.current then tostring(theme.current:get()) else "theme"
	end, function(): Node
		local ink = if theme and theme.get then theme.get("text.secondary") else nil
		return ui.div {
			w = size,
			h = size,
			shrink = 0,
			role = "status",
			label = label,
			bg_shader = SPIN,
			shader_clock = true,
			shader_params = { ink or "$text.secondary", { 0, 1, stroke, 0.18 } },
		}
	end)
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

-- A Paper file's id, from its address; nil when it isn't one.
local function file_id(url: any): string?
	if type(url) ~= "string" then
		return nil
	end
	return string.match(url, "^https://app%.paper%.design/file/([%w_%-]+)")
end

-- A design's address as the tab loads it: with Paper's own `minimal`, so its
-- panels start folded and the canvas has the room.
local function minimal(url: string): string
	if string.find(url, "[?&]minimal") then
		return url
	end
	return url .. (if string.find(url, "?", 1, true) then "&" else "?") .. "minimal"
end

local function open_tab(panel: any, session: any)
	local project = if session.project then zeron.context_of("project", session.project) else nil
	panel.open_tab {
		kind = KIND,
		title = zeron.s("tab.home"),
		icon = "palette",
		data = {
			key = `paper-{session.cwd or session.device or "local"}`,
			device = session.device,
			cwd = session.cwd,
			root = project and project.path,
		},
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
		-- The home's letter P (`panel_key`: { key, n }).
		local key = zeron.live("panel_key")
		local now = key()
		local seen = if type(now) == "table" then now.n else nil
		ui.effect(function()
			local k = key()
			if type(k) ~= "table" or k.n == seen then
				return
			end
			seen = k.n
			if string.upper(tostring(k.key or "")) == "P" then
				ui.after(0, function()
					open_tab(panel, session)
				end)
			end
		end)
		return PanelHome.Choice {
			id = "paper-open",
			icon = mark(PanelHome.ICON) :: any,
			label = zeron.t("row.label") :: any,
			key = "P",
			on_click = function()
				open_tab(panel, session)
			end,
		}
	end,
}

-- The tab's page, with a cookie profile of its own when Zeron's web views
-- give plugins one (Paper's sign-in kept apart and between runs).
local function page(id: string): any
	local ok, web = pcall(function()
		return (ui :: any).web(id, { profile = "paper" })
	end)
	if ok and web then
		return web
	end
	return (ui :: any).web(id)
end

-- Work going on: a ring alone, centred (its words for screen readers only).
local function working(): Node
	return ui.column {
		w_full = true,
		grow = 1,
		min_h = 0,
		items = "center",
		justify = "center",
		color = "$text.secondary",
		ring(16, zeron.s("loading")),
	}
end

-- Paper's mark on the quiet tile an empty state draws its glyph on (sm).
local function tile(): Node
	return ui.row {
		w = 36,
		h = 36,
		shrink = 0,
		aria_hidden = true,
		items = "center",
		justify = "center",
		rounded = "$radius.xl",
		bg = "$zeron.secondary.bg",
		border = 1,
		border_color = "$border.subtle",
		color = "$text.secondary",
		mark(18),
	}
end

-- A list of designs as one string, to tell when it changed.
local function signature(files: any): string
	local parts = {}
	for _, f in files or {} do
		table.insert(parts, `{f.name}\n{f.url}`)
	end
	return table.concat(parts, "\n\n")
end

-- WebKit's words for no network at all read as offline.
local function offline(e: any): boolean
	if type(e) ~= "string" then
		return false
	end
	local l = string.lower(e)
	return string.find(l, "offline", 1, true) ~= nil
		or string.find(l, "internet connection", 1, true) ~= nil
		or string.find(l, "not connected", 1, true) ~= nil
end

-- A design, live: the page alone, a ring while it first loads, and what went
-- wrong over it while it can't load, tried again by itself every few seconds.
-- Closing the tab is the way back.
local function design(data: any): Node
	local web = page(data.key)
	local url = minimal(data.url)
	local shown = ui.use_state(if type(web.url) == "string" and web.url ~= "" then "page" else "loading")
	if shown:peek() == "loading" then
		ui.after(0, function()
			web:load(url)
		end)
	end
	local function trouble(): boolean
		local e = web.error
		return type(e) == "string" and e ~= ""
	end
	ui.every(5000, function()
		if trouble() then
			local u = web.url
			web:load(if type(u) == "string" and u ~= "" then u else url)
		end
	end)
	return ui.column {
		relative = true,
		w_full = true,
		grow = 1,
		min_h = 0,
		(ui :: any).webview {
			id = `paper-view-{data.key}`,
			label = data.name or zeron.s("tab.home"),
			web = web,
			w_full = true,
			grow = 1,
			min_h = 0,
			on_navigate = function(e: any)
				if type(e) == "table" and (e.kind == "committed" or e.kind == "finished" or e.kind == "failed") then
					shown:set("page")
				end
			end,
		},
		ui.show(function(): boolean
			return shown:get() == "loading" and not trouble()
		end, ui.column {
			absolute = true,
			left = 0,
			right = 0,
			top = 0,
			bottom = 0,
			bg = "$background",
			working(),
		}),
		ui.show(trouble, ui.column {
			absolute = true,
			left = 0,
			right = 0,
			top = 0,
			bottom = 0,
			bg = "$background",
			ui.presence(function(): string
				return if offline(web.error) then "offline" else "failed"
			end, function(which: string): Node
				return EmptyState {
					icon = if which == "offline" then "wifi-off" else "danger-triangle",
					size = "sm",
					fill = true,
					title = zeron.t(`{which}.title`),
					body = zeron.t(`{which}.body`),
				}
			end, { w_full = true, grow = 1, min_h = 0 }),
		}),
	}
end

-- The Paper tab: agents' sign-in on the chat's device, then the designs the
-- checkout links, each opening in a tab of its own.
local function designs_tab(data: any): Node
	local device = data.device

	-- Agents' sign-in on the chat's device: { phase = "checking" | "in" |
	-- "out" | "asking" | "code" | "error", code?, url?, why? }.
	local agents = ui.use_state({ phase = "checking" } :: any)
	local function told(s: any)
		if type(s) ~= "table" then
			return
		end
		if s.signed_in then
			agents:set({ phase = "in" })
		elseif s.code then
			agents:set({ phase = "code", code = s.code, url = s.url })
		else
			agents:set({ phase = "out" })
		end
	end
	local function why(err: any): string
		local r = zeron.reason(err)
		return if REASONS[r] then r else "failed"
	end
	local function check(quiet: boolean?)
		if not quiet then
			agents:set({ phase = "checking" })
		end
		zeron.service(device):call("status", {}):after(told, function(err: any)
			agents:set({ phase = "error", why = why(err) })
		end)
	end
	check()

	local function signin()
		agents:set({ phase = "asking" })
		zeron.service(device):call("signin", {}):after(function(s: any)
			told(s)
			if type(s) == "table" and type(s.url) == "string" then
				zeron.open_url(s.url)
			end
		end, function(err: any)
			agents:set({ phase = "error", why = why(err) })
		end)
	end
	local function cancel()
		zeron.service(device):call("cancel", {}):after(told, function(err: any)
			agents:set({ phase = "error", why = why(err) })
		end)
	end

	-- The checkout's designs: { phase = "loading" | "ready" | "error",
	-- files?, why? }. Read again now and then, so a design an agent or a
	-- person links shows by itself.
	local list = ui.use_state({ phase = "loading" } :: any)
	local function designs(quiet: boolean?)
		if not quiet then
			list:set({ phase = "loading" })
		end
		zeron.service(device):call("designs", { cwd = data.cwd, root = data.root }):after(function(r: any)
			local files = if type(r) == "table" and type(r.files) == "table" then r.files else {}
			local was = list:peek()
			if was.phase == "ready" and signature(was.files) == signature(files) then
				return
			end
			list:set({ phase = "ready", files = files })
		end, function(err: any)
			list:set({ phase = "error", why = why(err) })
		end)
	end
	designs()

	-- Everything comes back by itself: a code out is asked about until it's
	-- approved, an error is tried again, and paper.json is read again.
	local beat = 0
	ui.every(3000, function()
		beat += 1
		local a = agents:peek()
		if a.phase == "code" or (a.phase == "error" and beat % 2 == 0) then
			check(true)
		elseif a.phase == "in" and beat % 2 == 0 then
			designs(list:peek().phase ~= "error")
		end
	end)

	local function open_design(f: any)
		local id = file_id(f.url)
		local panel = zeron.context("panel")
		if not id or not panel then
			return
		end
		panel.open_tab {
			kind = KIND,
			title = f.name or zeron.s("untitled"),
			icon = "palette",
			data = {
				key = `paper-file-{id}-{data.cwd or device or "local"}`,
				device = device,
				cwd = data.cwd,
				root = data.root,
				url = f.url,
				name = f.name,
			},
		}
	end

	-- New design: Paper makes a file, the service links it in paper.json,
	-- and it opens in its own tab.
	local making = ui.use_state(false)
	local function new_design()
		if making:peek() then
			return
		end
		making:set(true)
		zeron.service(device):call("create", { cwd = data.cwd, root = data.root }):after(function(r: any)
			making:set(false)
			designs(true)
			if type(r) == "table" and type(r.url) == "string" then
				open_design(r)
			end
		end, function(err: any)
			making:set(false)
			local said = if type(err) == "table" then err.message else err
			zeron.toast(if type(said) == "string" and said ~= "" then said else zeron.s("new_failed"))
		end)
	end

	-- The designs, as the panel's home lists what opens there: a heading,
	-- a row each, and New design under them as its Add action is.
	local room = ui.use_state(0)
	local function home(): Node
		return ui.scroll {
			id = "paper-home",
			role = "group",
			label = zeron.t("designs"),
			w_full = true,
			grow = 1,
			min_h = 0,
			overscroll = "contain",
			fade = { 24, 24 },
			fade_overflow = true,
			on_resize = function(size: { w: number, h: number })
				if room:peek() ~= size.h then
					room:set(size.h)
				end
			end,
			ui.column {
				w_full = true,
				min_h = function(): number
					return room:get()
				end,
				justify = "center",
				items = "center",
				ui.column {
					w_full = true,
					max_w = ui.theme.get("zeron.form.list") :: number?,
					px = "$space.4",
					py = "$space.6",
					gap = "$zeron.list.gap",
					PanelHome.Heading { label = zeron.t("designs") },
					ui.presence(function(): string
						return signature(list:get().files)
					end, function(): Node
						local rows: { Node } = {}
						for i, f in list:peek().files or {} do
							table.insert(
								rows,
								PanelHome.Row {
									id = `paper-design-{i}`,
									icon = "palette" :: any,
									label = f.name,
									on_click = function()
										open_design(f)
									end,
								} :: any
							)
						end
						return ui.column { w_full = true, gap = "$zeron.list.gap", table.unpack(rows) }
					end, { w_full = true }),
					ui.presence(function(): string
						return if making:get() then "making" else "new"
					end, function(which: string): Node
						return PanelHome.Row {
							id = "paper-new",
							icon = (if which == "making" then ring(16, zeron.s("making")) else "plus") :: any,
							label = zeron.t(if which == "making" then "making" else "new_design"),
							tone = "muted",
							on_click = new_design,
						}
					end, { w_full = true }),
				},
			},
		}
	end

	-- A code out: Zeron's empty state's page, its tile a ring, the code under
	-- its words, as Settings' provider rows show a sign-in's code.
	local function waiting(): Node
		return ui.column {
			id = "paper-signin",
			items = "center",
			justify = "center",
			gap = "$space.3",
			w_full = true,
			grow = 1,
			py = "$space.5",
			live = "polite",
			ui.row {
				w = 36,
				h = 36,
				shrink = 0,
				items = "center",
				justify = "center",
				color = "$text.secondary",
				ring(16, zeron.s("signing_in")),
			},
			ui.column {
				items = "center",
				gap = "$space.1",
				max_w = 340,
				ui.text {
					zeron.t("signing_in"),
					align = "center",
					text_size = "$font.size.md",
					line_height = "$font.line.md",
					weight = "$font.weight.medium",
					color = "$text.primary",
					wrap = true,
				},
				ui.text {
					zeron.t("code_check"),
					align = "center",
					text_size = "$font.size.sm",
					line_height = "$font.line.sm",
					color = "$text.secondary",
					wrap = true,
				},
			},
			ui.text {
				function(): string
					return agents:get().code or ""
				end,
				id = "paper-code",
				font = "$font.mono",
				text_size = "$font.size.lg",
				weight = "$font.weight.semibold",
				color = "$text.primary",
				selectable = true,
			},
			ui.row {
				gap = "$space.2",
				items = "center",
				pt = "$space.1",
				Button {
					zeron.t("open_page"),
					tone = "secondary",
					size = "sm",
					on_click = function()
						local u = agents:peek().url
						if type(u) == "string" then
							zeron.open_url(u)
						end
					end,
				},
				Button { zeron.t("cancel"), tone = "ghost", size = "sm", on_click = cancel },
			},
		}
	end

	-- What can't be reached yet, said once; it's tried again by itself.
	local function error_page(reason: string): Node
		return EmptyState {
			icon = if reason == "offline" then "wifi-off" else "danger-triangle",
			size = "sm",
			fill = true,
			title = zeron.t("unavailable.title"),
			body = zeron.t(`error.{reason}`),
		}
	end

	return ui.column {
		w_full = true,
		grow = 1,
		min_h = 0,
		ui.presence(function(): string
			local a = agents:get()
			if a.phase == "checking" or a.phase == "asking" then
				return "working"
			elseif a.phase == "out" then
				return "out"
			elseif a.phase == "error" then
				return `error.{a.why}`
			elseif a.phase == "code" then
				return "code"
			end
			local l = list:get()
			if l.phase == "loading" then
				return "working"
			elseif l.phase == "error" then
				return `error.{l.why}`
			end
			return if #(l.files or {}) == 0 then "empty" else "home"
		end, function(which: string): Node
			if which == "working" then
				return working()
			elseif which == "code" then
				return waiting()
			elseif which == "out" then
				return EmptyState {
					art = tile(),
					size = "sm",
					fill = true,
					title = zeron.t("signin.title"),
					body = zeron.t("signin.body"),
					action = { label = zeron.t("sign_in"), on_click = signin },
				}
			elseif string.sub(which, 1, 6) == "error." then
				return error_page(string.sub(which, 7))
			elseif which == "empty" then
				return ui.presence(function(): string
					return if making:get() then "making" else "new"
				end, function(state: string): Node
					if state == "making" then
						return working()
					end
					return EmptyState {
						art = tile(),
						size = "sm",
						fill = true,
						title = zeron.t("empty.title"),
						body = zeron.t("empty.body"),
						action = { label = zeron.t("new_design"), icon = "plus", on_click = new_design },
					}
				end, { w_full = true, grow = 1, min_h = 0 })
			end
			return home()
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end

zeron.tab(KIND, function(tab: any): Node
	local data = tab.data or {}
	if type(data.url) == "string" then
		return design(data)
	end
	return designs_tab(data)
end)
