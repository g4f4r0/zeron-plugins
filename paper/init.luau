--!strict
-- Paper: the chat's Paper designs, live in its panel. Agents reach Paper
-- through the two tools the service answers (paper_tools_list and
-- paper_tools_call); this window shows the canvas they work on.
--
-- The panel's empty page gets one Paper row (key P), as Desktop's. Its tab
-- first asks whether agents on the chat's device are signed in to Paper:
-- while they aren't, it says so as an empty page with Sign in, then shows
-- the code over Paper's own approval page, in the tab's view, where the
-- person is already signed in. Signed in, it lists the designs the
-- checkout links in its paper.json, drawn as the panel's home draws rows,
-- and New design. A design opens live in the same tab with a way back.
-- New design opens Paper's home: the design the person makes (or opens)
-- there is linked in the checkout's paper.json.
--
-- The view is drawn as Zeron's own browser tab draws a page: a ring while
-- it first loads, and what went wrong over it when it can't.

local zeron = require("./zeron")("paper")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")
local Progress = require("@ds/progress")
local Button = require("@ds/button")
local IconButton = require("@ds/icon_button").IconButton

local KIND = "canvas"
local HOME = "https://app.paper.design/"

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
			icon = "palette" :: any,
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

	-- What the tab shows once agents are signed in: the designs ("home"), a
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
	local function check()
		agents:set({ phase = "checking" })
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
				load(s.url)
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
	-- A code out: asked again now and then until it's approved.
	ui.every(3000, function()
		if agents:peek().phase ~= "code" then
			return
		end
		zeron.service(device):call("status", {}):after(told, function() end)
	end)

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
	end

	-- New design: the file the page reaches is linked in paper.json, once.
	local linking = false
	ui.every(1000, function()
		if linking or view:peek().at ~= "new" or agents:peek().phase ~= "in" then
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

	-- The bar over the view: the code while one is out, else the way back.
	local function top(): Node
		return ui.presence(function(): string
			if agents:get().phase == "code" then
				return "code"
			end
			return view:get().at
		end, function(which: string): Node
			if which == "code" then
				return bar(
					"paper-signin",
					ui.div {
						shrink = 0,
						px = "$space.1",
						color = "$text.secondary",
						Progress.ProgressRing { size = 12, tone = "neutral", label = zeron.t("signing_in") },
					},
					ui.text {
						zeron.t("code_check"),
						grow = 1,
						min_w = 0,
						color = "$text.secondary",
						text_size = "$font.size.sm",
						line_height = "$font.line.sm",
						wrap = true,
					},
					ui.text {
						function(): string
							return agents:get().code or ""
						end,
						id = "paper-code",
						shrink = 0,
						font = "$font.mono",
						text_size = "$font.size.lg",
						weight = "$font.weight.semibold",
						color = "$text.primary",
						selectable = true,
					},
					Button {
						zeron.t("open_page"),
						tone = "ghost",
						size = "sm",
						on_click = function()
							local u = agents:peek().url
							if type(u) == "string" then
								load(u)
							end
						end,
					},
					Button { zeron.t("cancel"), tone = "secondary", size = "sm", on_click = cancel }
				)
			end
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
					working(zeron.t("loading")),
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
			local a = agents:get()
			if a.phase == "checking" or a.phase == "asking" then
				return "working"
			elseif a.phase == "out" then
				return "out"
			elseif a.phase == "error" then
				return `error.{a.why}`
			elseif a.phase == "code" then
				return "canvas"
			end
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
			return if #(l.files or {}) == 0 then "empty" else "home"
		end, function(which: string): Node
			if which == "working" then
				return working(zeron.t("loading"))
			elseif which == "out" then
				return EmptyState {
					icon = "palette",
					size = "sm",
					fill = true,
					title = zeron.t("signin.title"),
					body = zeron.t("signin.body"),
					action = { label = zeron.t("sign_in"), on_click = signin },
				}
			elseif string.sub(which, 1, 6) == "error." then
				return error_page(string.sub(which, 7), check)
			elseif string.sub(which, 1, 5) == "list." then
				return error_page(string.sub(which, 6), designs)
			elseif which == "empty" then
				return EmptyState {
					icon = "palette",
					size = "sm",
					fill = true,
					title = zeron.t("empty.title"),
					body = zeron.t("empty.body"),
					action = { label = zeron.t("new_design"), icon = "plus", on_click = new_design },
				}
			elseif which == "home" then
				return home()
			end
			return canvas()
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end)
