--!strict
-- Paper: the chat's Paper designs, live in its panel. Agents reach Paper
-- through Paper's own MCP server, set up in each harness with its own
-- sign-in; this window shows the canvas they work on.
--
-- The panel's empty page gets one Paper row (key P), as Desktop's. Its tab
-- lists the designs the checkout links in its paper.json, drawn as the
-- panel's home draws rows, with New design under them, and then the agent
-- harnesses on the chat's device and where each stands with Paper. One not
-- yet set up or signed in copies the command that does it. A design opens
-- live in the same tab with a way back. New design opens Paper's home: the
-- design the person makes (or opens) there is linked in paper.json.
--
-- The view is drawn as Zeron's own browser tab draws a page: a ring while
-- it first loads, and what went wrong over it when it can't.

local zeron = require("./zeron")("paper")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")
local IconButton = require("@ds/icon_button").IconButton
local AgentMark = require("@ds/agent_mark")
local Badge = require("@ds/badge").Badge

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

-- A Paper file's address alone (no page, no query); nil when it isn't one.
local function file_link(url: any): string?
	if type(url) ~= "string" then
		return nil
	end
	local id = string.match(url, "^https://app%.paper%.design/file/([%w_%-]+)")
	return if id then `https://app.paper.design/file/{id}` else nil
end

-- A page's title as a design's name (Paper's own name for itself taken off).
local function name_of(title: any): string?
	if type(title) ~= "string" then
		return nil
	end
	local t = string.match(title, "^%s*(.-)%s*$") or ""
	for _, sep in { " - ", " | ", " – ", " — ", " · " } do
		local tail = sep .. "Paper"
		if #t > #tail and string.sub(t, -#tail) == tail then
			t = string.sub(t, 1, #t - #tail)
			break
		end
	end
	if t == "" or t == "Paper" then
		return nil
	end
	return t
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

-- A line of the bar over the view: secondary words, a line at most.
local function words(text: any): Node
	return ui.text {
		text,
		grow = 1,
		min_w = 0,
		color = "$text.secondary",
		text_size = "$font.size.sm",
		line_height = "$font.line.sm",
		truncate = true,
	}
end

-- The bar over the view, as the browser tab's: 40 high, its controls quiet.
local function bar(id: string, ...: Node): Node
	return ui.row {
		id = id,
		w_full = true,
		min_h = 40,
		shrink = 0,
		px = "$space.2",
		py = "$space.1",
		gap = "$space.2",
		items = "center",
		live = "polite",
		...,
	}
end

zeron.tab(KIND, function(tab: any): Node
	local data = tab.data or {}
	local device = data.device
	local web = page(`paper-{data.key or "home"}`)

	-- What the tab shows: the designs and agents ("home"), a
	-- design ("design", with its url and name) or Paper's home to make one
	-- ("new").
	local view = ui.use_state({ at = "home" } :: any)
	-- The page: "loading" until a load commits, then "page".
	local shown = ui.use_state("loading")
	local dismissed = ui.use_state(false)
	local function load(url: string)
		shown:set("loading")
		dismissed:set(false)
		web:load(url)
	end

	local function why(err: any): string
		local r = zeron.reason(err)
		return if REASONS[r] then r else "failed"
	end

	-- The harnesses on the chat's device and where each stands with Paper:
	-- { phase = "loading" | "ready" | "error", agents?, why? }.
	local harnesses = ui.use_state({ phase = "loading" } :: any)
	local function check()
		harnesses:set({ phase = "loading", agents = harnesses:peek().agents })
		zeron.service(device):call("agents", {}):after(function(r: any)
			harnesses:set({ phase = "ready", agents = if type(r) == "table" and type(r.agents) == "table" then r.agents else {} })
		end, function(err: any)
			harnesses:set({ phase = "error", why = why(err) })
		end)
	end
	check()

	-- A harness not ready yet: the command that sets it up or signs it in,
	-- copied to run in a terminal on the chat's device.
	local function copy(a: any)
		if type(a.command) ~= "string" then
			return
		end
		pcall(ui.clipboard.write, a.command)
		zeron.toast(zeron.s("copied", { command = a.command }))
	end

	-- The checkout's designs: { phase = "loading" | "ready" | "error",
	-- files?, why? }.
	local list = ui.use_state({ phase = "loading" } :: any)
	local function designs()
		list:set({ phase = "loading" })
		zeron.service(device):call("designs", { cwd = data.cwd, root = data.root }):after(function(r: any)
			list:set({ phase = "ready", files = if type(r) == "table" and type(r.files) == "table" then r.files else {} })
		end, function(err: any)
			list:set({ phase = "error", why = why(err) })
		end)
	end
	designs()

	local function open_design(f: any)
		view:set({ at = "design", url = f.url, name = f.name })
		load(f.url)
	end
	local function new_design()
		view:set({ at = "new" })
		load(HOME)
	end
	local function back()
		view:set({ at = "home" })
		designs()
		check()
	end

	-- New design: the file the page reaches is linked in paper.json, once.
	local linking = false
	ui.every(1000, function()
		if linking or view:peek().at ~= "new" then
			return
		end
		local url = file_link(web.url)
		if not url then
			return
		end
		linking = true
		local name = name_of(web.title) or zeron.s("untitled")
		zeron.service(device)
			:call("link", { cwd = data.cwd, root = data.root, name = name, url = url })
			:after(function(r: any)
				linking = false
				if view:peek().at == "new" then
					view:set({ at = "design", url = url, name = name })
				end
				if type(r) == "table" and r.linked then
					zeron.toast(zeron.s("linked"))
				end
			end, function(err: any)
				linking = false
				if view:peek().at == "new" then
					view:set({ at = "design", url = url, name = name })
				end
				local said = if type(err) == "table" then err.message else err
				zeron.toast(if type(said) == "string" and said ~= "" then said else zeron.s("link_failed"))
			end)
	end)

	local function trouble(): boolean
		local e = web.error
		return type(e) == "string" and e ~= "" and not dismissed:get()
	end

	-- The bar over the view: the way back, what's shown, and reload.
	local function top(): Node
		return ui.presence(function(): string
			return view:get().at
		end, function(which: string): Node
			return bar(
				"paper-bar",
				IconButton {
					icon = "arrow-left",
					label = zeron.t("designs"),
					tooltip_side = "bottom",
					tone = "quiet",
					on_click = back,
				},
				words(if which == "new"
					then zeron.t("new_hint")
					else function(): string
						return view:get().name or ""
					end),
				IconButton {
					icon = "refresh",
					label = zeron.t("reload"),
					tooltip_side = "bottom",
					tone = "quiet",
					on_click = function()
						local u = web.url
						load(if type(u) == "string" and u ~= "" then u else HOME)
					end,
				}
			)
		end, { w_full = true })
	end

	-- The view, as the browser tab draws its page.
	local function canvas(): Node
		return ui.column {
			w_full = true,
			grow = 1,
			min_h = 0,
			top(),
			ui.column {
				relative = true,
				w_full = true,
				grow = 1,
				min_h = 0,
				(ui :: any).webview {
					id = `paper-view-{data.key or "home"}`,
					label = zeron.t("tab.home"),
					web = web,
					w_full = true,
					grow = 1,
					min_h = 0,
					on_navigate = function(e: any)
						if type(e) ~= "table" then
							return
						end
						if e.kind == "started" then
							dismissed:set(false)
						elseif e.kind == "committed" or e.kind == "finished" or e.kind == "failed" then
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
							body = if which == "offline"
								then zeron.t("offline.body")
								else function(): string
									return web.error or ""
								end,
							action = {
								label = zeron.t("retry"),
								on_click = function()
									local u = web.url
									load(if type(u) == "string" and u ~= "" then u else HOME)
								end,
							},
							secondary = {
								label = zeron.t("dismiss"),
								on_click = function()
									dismissed:set(true)
								end,
							},
						}
					end, { w_full = true, grow = 1, min_h = 0 }),
				}),
			},
		}
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
						local l = list:get()
						return `{#(l.files or {})}`
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
					PanelHome.Row {
						id = "paper-new",
						icon = "plus" :: any,
						label = zeron.t("new_design"),
						tone = "muted",
						on_click = new_design,
					},
					ui.div { h = "$space.4", shrink = 0 },
					PanelHome.Heading {
						label = zeron.t("agents"),
						trail = IconButton {
							icon = "refresh",
							label = zeron.t("check_again"),
							size = "sm",
							tone = "quiet",
							on_click = check,
						},
					},
					ui.presence(function(): string
						local h = harnesses:get()
						if h.phase == "error" then
							return `error.{h.why}`
						end
						local parts = { h.phase }
						for _, a in h.agents or {} do
							table.insert(parts, `{a.id}:{a.state}`)
						end
						return table.concat(parts, ",")
					end, function(which: string): Node
						local h = harnesses:peek()
						if string.sub(which, 1, 6) == "error." then
							return PanelHome.Row {
								id = "paper-agents-error",
								icon = "danger-triangle" :: any,
								label = zeron.t(`error.{h.why}`),
								tone = "muted",
								on_click = check,
							}
						end
						if h.agents == nil then
							return ui.row { w_full = true, h = PanelHome.ROW_H, items = "center", justify = "center", ring(16, zeron.s("loading")) }
						end
						if #h.agents == 0 then
							return PanelHome.Row { id = "paper-agents-none", icon = "info" :: any, label = zeron.t("no_agents"), tone = "muted" }
						end
						local rows: { Node } = {}
						for _, a in h.agents do
							local tone = if a.state == "in" then "success" elseif a.state == "error" then "danger" else "neutral"
							table.insert(
								rows,
								PanelHome.Row {
									id = `paper-agent-{a.id}`,
									icon = AgentMark { label = a.name, mark = a.mark, size = PanelHome.ICON, bare = true } :: any,
									label = a.name,
									tooltip = if type(a.command) == "string" then zeron.s("copy_hint", { command = a.command }) else a.why,
									trail = Badge { zeron.t(`state.{a.state}`), tone = tone :: any, dot = true },
									on_click = if type(a.command) == "string"
										then function()
											copy(a)
										end
										else nil,
								} :: any
							)
						end
						return ui.column { w_full = true, gap = "$zeron.list.gap", table.unpack(rows) }
					end, { w_full = true }),
				},
			},
		}
	end

	local function error_page(reason: string, again: () -> ()): Node
		return EmptyState {
			icon = if reason == "offline" then "wifi-off" else "danger-triangle",
			size = "sm",
			fill = true,
			title = zeron.t("unavailable.title"),
			body = zeron.t(`error.{reason}`),
			action = { label = zeron.t("retry"), on_click = again },
		}
	end

	return ui.column {
		w_full = true,
		grow = 1,
		min_h = 0,
		ui.presence(function(): string
			local at = view:get().at
			if at ~= "home" then
				return "canvas"
			end
			local l = list:get()
			if l.phase == "loading" then
				return "working"
			elseif l.phase == "error" then
				return `list.{l.why}`
			end
			return "home"
		end, function(which: string): Node
			if which == "working" then
				return working()
			elseif string.sub(which, 1, 5) == "list." then
				return error_page(string.sub(which, 6), designs)
			elseif which == "home" then
				return home()
			end
			return canvas()
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end)
