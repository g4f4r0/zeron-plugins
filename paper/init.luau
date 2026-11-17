--!strict
-- Paper: the chat's Paper designs, live in its panel. Agents reach Paper
-- through the two tools the service answers (list_tools and
-- call_tool); this window shows the canvas they work on.
--
-- The panel's empty page gets one Paper row (key P), as Desktop's. Its tab
-- first asks whether agents on the chat's device are signed in to Paper:
-- while they aren't, it says so as an empty page with Sign in. Sign in
-- shows Paper's approval page in the tab itself, so the one login there
-- signs in both agents and the canvas (Paper's site, in the same cookies).
-- Signed in, it lists the designs the
-- checkout links in its paper.json, drawn as the panel's home draws rows,
-- and New design, which makes a file in Paper and links it. A design opens
-- live in the same tab, in place of the list, with Paper's panels folded
-- (`minimal`) and no bar; closing the tab is the way back.
--
-- Nothing asks to be reloaded: the list reads paper.json again now and then,
-- and what can't be reached is tried again by itself. A design is drawn as
-- Zeron's own browser tab draws a page: a ring while it first loads, and
-- what went wrong over it while it can't.

local zeron = require("./zeron")("paper")
local PanelHome = require("@ds/panel_home")
local EmptyState = require("@ds/empty_state")

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
			project = project and project.name,
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
-- give plugins one (Paper's sign-in kept apart and between runs), and the
-- page able to tell the tab things (`window.zgx.postMessage`), which copy
-- and paste go through.
--
-- Paper edits only in Chrome: it reads the user agent for "Chrome/" and,
-- without it, opens every file view-only ("Your browser doesn't support
-- features required by Paper"). Zeron's web view on macOS is WebKit, so the
-- page says it's Chrome. (Paper reads the system from `navigator.platform`,
-- which stays the device's own.) The page's id carries `ua` so a page made
-- before this, which kept WebKit's own agent, isn't reused.
local AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
local function page(key: string): any
	local id = `{key}-ua`
	local ok, web = pcall(function()
		return (ui :: any).web(id, { profile = "paper", messages = true, user_agent = AGENT })
	end)
	if ok and web then
		return web
	end
	return (ui :: any).web(id, { messages = true, user_agent = AGENT })
end

-- Copy and paste. Zeron's web view doesn't give a page this device's
-- clipboard (on macOS the page hears Cmd+C and Cmd+V, and nothing is
-- copied or pasted), so the page hands both keys to the tab:
--
-- - Copy and cut run WebKit's own command, so Paper's handler fills the
--   clipboard with all it gives (its nodes as HTML too). Its text is sent
--   here as well, and put on the clipboard where it didn't arrive.
-- - Paste asks the tab what the clipboard holds. Text comes back and goes in
--   as Paper's own paste event (with the HTML of the page's last copy when
--   it's that same text, so copied nodes paste as nodes). A picture can't be
--   handed over as data, so for one the page asks WebKit to paste it.
-- - Paper's menus (Paste, Copy link, Copy as code) use the Clipboard API,
--   which goes the same way.
--
-- Only Paper's own pages (the main frame) are answered, and only while
-- Zeron's window is in front.
local CLIP_JS = [==[
(() => {
  if (window.__zeronPaperClip || !window.zgx) return;
  const send = (m) => {
    try { window.zgx.postMessage(Object.assign({ kind: 'paper-clip' }, m)); } catch (x) {}
  };
  const mac = /Mac|iPhone|iPad|iPod/.test(navigator.platform || '');
  const norm = (s) => String(s == null ? '' : s).replace(/\r\n?/g, '\n');
  const now = () => (window.performance ? performance.now() : Date.now());

  // What this page last copied, with Paper's HTML (its nodes): the device's
  // clipboard gives back the text alone, so a paste of that same text gets
  // the HTML again.
  let own = null;
  const remember = (text, html) => { own = html ? { text: norm(text), html } : null; };

  // Asking Zeron what the device's clipboard holds: { text, image }.
  let seq = 0;
  const waiting = new Map();
  const ask = (done) => {
    const id = ++seq;
    const timer = setTimeout(() => { if (waiting.delete(id)) done(null); }, 3000);
    waiting.set(id, (a) => { clearTimeout(timer); done(a); });
    send({ op: 'read', id });
  };

  const focused = () => {
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el && el !== document.documentElement ? el : (document.body || document.documentElement);
  };
  const editable = (el) => !!el && (el.isContentEditable || el.tagName === 'TEXTAREA' ||
    (el.tagName === 'INPUT' && /^(text|search|url|tel|email|password|number|)$/i.test(el.getAttribute('type') || '')));
  const selected = () => {
    const el = focused();
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
      try { return el.value.slice(el.selectionStart, el.selectionEnd); } catch (x) { return ''; }
    }
    return String(window.getSelection() || '');
  };

  // Copy and cut: WebKit's own command first, so Paper's handler fills the
  // clipboard with everything it gives (its HTML too). What it put there is
  // noted as it's set; where the command is refused, the copy runs into a
  // transfer of the tab's own and its text goes to the device's clipboard.
  let recording = null;
  const hook = (e) => {
    const got = recording;
    const d = e.clipboardData;
    if (!got || !d) return;
    const set = d.setData;
    try {
      d.setData = function (type, value) {
        let t = String(type).toLowerCase();
        if (t === 'text') t = 'text/plain';
        got[t] = String(value);
        return set.call(d, type, value);
      };
    } catch (x) {}
  };
  addEventListener('copy', hook, true);
  addEventListener('cut', hook, true);

  const copy = (cut) => {
    const el = focused();
    const sel = selected();
    const got = {};
    recording = got;
    let ok = false;
    try { ok = document.execCommand(cut ? 'cut' : 'copy'); } catch (x) {}
    recording = null;
    let text = got['text/plain'];
    let html = got['text/html'];
    if (!ok) {
      let taken = false;
      try {
        const data = new DataTransfer();
        const ev = new ClipboardEvent(cut ? 'cut' : 'copy', { clipboardData: data, bubbles: true, cancelable: true, composed: true });
        el.dispatchEvent(ev);
        taken = ev.defaultPrevented;
        text = data.getData('text/plain');
        html = data.getData('text/html');
      } catch (x) {}
      if (!taken) {
        text = sel;
        html = '';
        if (cut && sel && editable(el)) document.execCommand('delete');
      }
    } else if (text == null && html == null) {
      text = sel;
    }
    remember(text, html);
    if (text) send({ op: 'copied', text: String(text) });
  };

  // Paste: Paper's own paste event, carrying what the device's clipboard
  // holds. Text comes from Zeron; a picture only WebKit can read, so for one
  // the page's own paste is asked for (WebKit's, then the Clipboard API's).
  let pasting = false;
  let trusted = -1e9;
  let pending = 0;
  addEventListener('paste', (e) => {
    if (e.isTrusted && !pasting) { trusted = now(); pending = 0; }
  }, true);

  const give = (el, text, html, files) => {
    let taken = false;
    try {
      const data = new DataTransfer();
      if (text) data.setData('text/plain', text);
      if (html) data.setData('text/html', html);
      for (const f of files || []) data.items.add(f);
      const ev = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true, composed: true });
      el.dispatchEvent(ev);
      taken = ev.defaultPrevented;
    } catch (x) {}
    if (!taken && text && editable(el)) document.execCommand('insertText', false, text);
  };

  const original = {};
  const cb = navigator.clipboard;
  if (cb) {
    for (const k of ['read', 'readText', 'write', 'writeText']) if (typeof cb[k] === 'function') original[k] = cb[k].bind(cb);
  }

  const native = (el, text) => {
    let ok = false;
    pasting = true;
    try { ok = document.execCommand('paste'); } catch (x) {}
    pasting = false;
    if (ok) return;
    if (!original.read) { if (text) give(el, text, null, []); return; }
    original.read().then(async (items) => {
      let t = null, h = null;
      const files = [];
      for (const item of items || []) {
        for (const type of item.types || []) {
          const blob = await item.getType(type);
          if (type === 'text/plain' && t == null) t = await blob.text();
          else if (type === 'text/html' && h == null) h = await blob.text();
          else if (type.startsWith('image/')) files.push(new File([blob], 'image.' + (type === 'image/svg+xml' ? 'svg' : type.split('/')[1]), { type }));
        }
      }
      give(el, t != null ? t : text, h, files);
    }).catch(() => { if (text) give(el, text, null, []); });
  };

  const paste = () => {
    if (now() - trusted < 200) return;
    const el = focused();
    const mine = ++pending;
    ask((a) => {
      if (pending !== mine) return;
      pending = 0;
      const text = a && typeof a.text === 'string' && a.text !== '' ? a.text : null;
      if (a && a.image) return native(el, text);
      if (text != null) return give(el, text, own && own.text === norm(text) ? own.html : null, []);
      native(el, null);
    });
  };

  addEventListener('keydown', (e) => {
    const mod = mac ? (e.metaKey && !e.ctrlKey) : (e.ctrlKey && !e.metaKey);
    if (!mod || e.altKey || e.shiftKey || e.isComposing) return;
    const key = /^[a-z]$/i.test(e.key || '') ? e.key.toLowerCase() : ({ KeyC: 'c', KeyX: 'x', KeyV: 'v' })[e.code];
    if (key !== 'c' && key !== 'x' && key !== 'v') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.repeat) return;
    if (key === 'v') paste(); else copy(key === 'x');
  }, true);

  // Paper's menus (Paste, Paste over, Copy link, Copy as code) use the
  // Clipboard API: reads come from Zeron as a paste does, and what's written
  // reaches the device's clipboard even where WebKit refuses it.
  const items = (a) => {
    const text = a && typeof a.text === 'string' ? a.text : '';
    const parts = { 'text/plain': new Blob([text], { type: 'text/plain' }) };
    if (own && own.text === norm(text)) parts['text/html'] = new Blob([own.html], { type: 'text/html' });
    return [new ClipboardItem(parts)];
  };
  const wrote = async (list) => {
    let text = null, html = null;
    for (const item of list || []) {
      for (const type of item.types || []) {
        if (type === 'text/plain' && text == null) text = await (await item.getType(type)).text();
        if (type === 'text/html' && html == null) html = await (await item.getType(type)).text();
      }
    }
    remember(text, html);
    if (text) send({ op: 'copied', text });
  };
  const define = (k, fn) => { try { Object.defineProperty(cb, k, { value: fn, configurable: true, writable: true }); } catch (x) {} };
  if (cb) {
    define('read', () => new Promise((resolve, reject) => ask((a) => {
      if (a && a.image && original.read) return original.read().then(resolve, reject);
      if (!a && original.read) return original.read().then(resolve, reject);
      resolve(items(a));
    })));
    define('readText', () => new Promise((resolve, reject) => ask((a) => {
      if (a && typeof a.text === 'string') return resolve(a.text);
      if (original.readText) return original.readText().then(resolve, reject);
      resolve('');
    })));
    define('write', async (list) => {
      try { if (original.write) await original.write(list); } catch (x) {}
      await wrote(list);
    });
    define('writeText', async (text) => {
      try { if (original.writeText) await original.writeText(text); } catch (x) {}
      remember(text, null);
      if (text) send({ op: 'copied', text: String(text) });
    });
  }

  window.__zeronPaperClip = {
    answer: (id, a) => {
      const done = waiting.get(id);
      if (!done) return;
      waiting.delete(id);
      done(a);
    },
  };
})();
]==]
local CLIP_ORIGINS = { ["https://app.paper.design"] = true, ["https://login.paper.design"] = true }

local function js_value(v: any): string
	local ok, lit = pcall(ui.json.encode, v)
	if ok and type(lit) == "string" then
		return (string.gsub(string.gsub(lit, "\226\128\168", "\\u2028"), "\226\128\169", "\\u2029"))
	end
	return "null"
end

local function lines(s: string): string
	return (string.gsub(s, "\r\n?", "\n"))
end

local function clipboard(web: any, value: any, origin: string, main_frame: boolean)
	if not main_frame or type(value) ~= "table" or value.kind ~= "paper-clip" or not CLIP_ORIGINS[origin] then
		return
	end
	local active = zeron.window(true).active
	if value.op == "copied" and type(value.text) == "string" and value.text ~= "" and active then
		-- Written only where WebKit's copy didn't arrive, so its HTML stays.
		local ok, held = pcall(ui.clipboard.read)
		if not ok or type(held) ~= "string" or lines(held) ~= lines(value.text) then
			pcall(ui.clipboard.write, value.text)
		end
	elseif value.op == "read" and type(value.id) == "number" then
		local id = math.floor(value.id)
		local function answer(a: any)
			web:run(`window.__zeronPaperClip && window.__zeronPaperClip.answer({id}, {js_value(a)});`)
		end
		if not active then
			answer(nil)
			return
		end
		local ok, text = pcall(ui.clipboard.read)
		local said = if ok and type(text) == "string" then text else nil
		local got, picture = pcall(ui.clipboard.read_image)
		if got and picture then
			picture:after(function(image: any)
				answer({ text = said, image = image ~= nil })
			end, function()
				answer({ text = said, image = false })
			end)
		else
			answer({ text = said, image = false })
		end
	end
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

-- A tab's page for designs: the web page, whether it has shown yet, and
-- loads tried again by themselves every few seconds while they fail. Made
-- at the top of a tab's build (it holds state).
type Viewer = { web: any, shown: any, open: (url: string) -> (), go: (url: string) -> (), trouble: () -> boolean }
local function viewer(key: string): Viewer
	local web = page(key)
	local shown = ui.use_state(if type(web.url) == "string" and web.url ~= "" then "page" else "loading")
	local wanted: string? = nil
	local function trouble(): boolean
		local e = web.error
		return type(e) == "string" and e ~= ""
	end
	ui.every(5000, function()
		if wanted and trouble() then
			local u = web.url
			web:load(if type(u) == "string" and u ~= "" then u else wanted)
		end
	end)
	local function go(u: string)
		wanted = u
		if web.url ~= u then
			shown:set("loading")
			web:load(u)
		end
	end
	return {
		web = web,
		shown = shown,
		trouble = trouble,
		go = go,
		open = function(url: string)
			go(minimal(url))
		end,
	}
end

-- Paper's site keeps its own sign-in, in the page's cookies. Once a design
-- has loaded, the page asks Paper who's signed in; signed out, it goes
-- through Paper's sign-in, which comes straight back while Paper's login
-- (login.paper.design) knows the person, as it does once they've approved
-- agents' sign-in in this same page. Tried once a load, so a refusal can't
-- loop.
local SIGNED_IN = [[
(function () {
  if (!/^\/file\//.test(location.pathname) || sessionStorage.getItem("zeronPaperSignIn") === location.href) return;
  fetch("https://api.paper.design/auth/me", { credentials: "include" }).then(function (r) {
    if (r.status !== 401) return;
    sessionStorage.setItem("zeronPaperSignIn", location.href);
    location.replace("https://api.paper.design/auth/sign-in?final_redirect_uri=" + encodeURIComponent(location.href));
  }).catch(function () {});
})();
]]

-- A design, live: the page alone, a ring while it first loads, and what went
-- wrong over it while it can't load. Closing the tab is the way back.
local function design(v: Viewer, label: string, key: string): Node
	local web, shown, trouble = v.web, v.shown, v.trouble
	return ui.column {
		relative = true,
		w_full = true,
		grow = 1,
		min_h = 0,
		(ui :: any).webview {
			id = `paper-view-{key}`,
			label = label,
			web = web,
			w_full = true,
			grow = 1,
			min_h = 0,
			on_message = function(value: any, origin: string, main_frame: boolean)
				clipboard(web, value, origin, main_frame)
			end,
			on_navigate = function(e: any)
				if type(e) == "table" and (e.kind == "committed" or e.kind == "finished" or e.kind == "failed") then
					shown:set("page")
				end
				local url = web.url
				if type(e) == "table" and e.kind == "finished" and type(url) == "string" then
					if string.match(url, "^https://app%.paper%.design/") or string.match(url, "^https://login%.paper%.design/") then
						web:run(CLIP_JS)
					end
					if string.match(url, "^https://app%.paper%.design/file/") then
						web:run(SIGNED_IN)
					end
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
	-- The tab's page: agents' sign-in is approved in it (so Paper's site,
	-- in the same cookies, is signed in too), then designs open in it.
	local v = viewer(`paper-{data.key or "home"}`)

	-- Agents' sign-in on the chat's device: { phase = "checking" | "in" |
	-- "out" | "asking" | "code" | "error", code?, url?, why? }.
	local agents = ui.use_state({ phase = "checking" } :: any)
	local approving: string? = nil
	local function told(s: any)
		if type(s) ~= "table" then
			return
		end
		if s.signed_in then
			agents:set({ phase = "in" })
		elseif s.code then
			agents:set({ phase = "code", code = s.code, url = s.url })
			-- Its approval page, once a code (it moves on as the person
			-- signs in, so it isn't loaded again while they do).
			if type(s.url) == "string" and s.code ~= approving then
				approving = s.code
				v.go(s.url)
			end
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
		zeron.service(device):call("signin", {}):after(told, function(err: any)
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

	-- A design opens here, in place of the list.
	local opened = ui.use_state(nil :: any)
	local function open_design(f: any)
		if type(f) ~= "table" or type(f.url) ~= "string" then
			return
		end
		opened:set({ url = f.url, name = f.name })
		v.open(f.url)
	end

	-- New design: Paper makes a file, the service links it in paper.json,
	-- and it opens here.
	local making = ui.use_state(false)
	local function new_design()
		if making:peek() then
			return
		end
		making:set(true)
		zeron.service(device):call("create", { cwd = data.cwd, root = data.root, name = data.project }):after(function(r: any)
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
			if opened:get() then
				return "design"
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
				return design(v, zeron.s("signing_in"), data.key or "home")
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
			elseif which == "design" then
				return design(v, (opened:peek() or {}).name or zeron.s("tab.home"), data.key or "home")
			end
			return home()
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end

zeron.tab(KIND, function(tab: any): Node
	local data = tab.data or {}
	-- A design in a tab of its own (as 0.4.0 opened them).
	if type(data.url) == "string" then
		local v = viewer(data.key)
		ui.after(0, function()
			v.open(data.url)
		end)
		return design(v, data.name or zeron.s("tab.home"), data.key)
	end
	return designs_tab(data)
end)
