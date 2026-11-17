--!strict
-- Paper's cloud MCP server (mcp.paper.design) for every agent, from one
-- place: this service holds the one Paper sign-in on its device and passes
-- MCP's tools/list and tools/call through unchanged.
--
-- Sign-in is OAuth's device flow, as fits a server with no browser: the
-- service registers itself with login.paper.design once, asks for a code,
-- and the person approves it at login.paper.design/device. Paper's access
-- tokens last minutes and each refresh token works once, so refreshing runs
-- one at a time, here only.

local zeron = require("./zeron")("paper")

local MCP = "https://mcp.paper.design/"
local LOGIN = "https://login.paper.design"
-- The resource tokens are for (RFC 8707): asked for on every token request,
-- or Paper's login hands back a token for the client alone, which the MCP
-- server refuses.
local RESOURCE = "https://mcp.paper.design"
local PROTOCOL = "2025-06-18"
local VERSION = "0.3.1"

local auth = zeron.store("auth", {} :: any)

type Pending = { device_code: string, code: string, url: string, expires: number, interval: number }
local pending: Pending? = nil

local function form(t: { [string]: string }): string
	local parts = {}
	for k, v in t do
		local e = string.gsub(v, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
		table.insert(parts, `{k}={e}`)
	end
	return table.concat(parts, "&")
end

local function decode(body: string?): any
	if type(body) ~= "string" or body == "" then
		return nil
	end
	local ok, v = pcall(zeron.json.decode, body)
	return if ok then v else nil
end

local function header(h: any, name: string): string?
	if type(h) ~= "table" then
		return nil
	end
	for k, v in h do
		if string.lower(tostring(k)) == name then
			return if type(v) == "table" then tostring(v[1]) else tostring(v)
		end
	end
	return nil
end

local function post_form(path: string, fields: { [string]: string }): (number, any)
	local r = zeron.fetch(LOGIN .. path, {
		method = "POST",
		headers = { ["content-type"] = "application/x-www-form-urlencoded", accept = "application/json" },
		body = form(fields),
		timeout = 30,
	}):await()
	return r.status, decode(r.body)
end

-- This service's OAuth client at Paper, registered once.
local function client_id(): string
	local a = auth:get()
	if type(a.client_id) == "string" then
		return a.client_id
	end
	local r = zeron.fetch(LOGIN .. "/oauth2/register", {
		method = "POST",
		headers = { ["content-type"] = "application/json", accept = "application/json" },
		body = zeron.json.encode({
			client_name = "Zeron Paper",
			grant_types = { "urn:ietf:params:oauth:grant-type:device_code", "refresh_token", "authorization_code" },
			redirect_uris = { "http://127.0.0.1/callback" },
			response_types = { "code" },
			token_endpoint_auth_method = "none",
		}),
		timeout = 30,
	}):await()
	local d = decode(r.body)
	if r.status >= 300 or type(d) ~= "table" or type(d.client_id) ~= "string" then
		error(`Paper refused to register Zeron (HTTP {r.status})`, 0)
	end
	auth:set({ client_id = d.client_id })
	return d.client_id
end

local function keep(d: any)
	local a = auth:get()
	auth:set({
		client_id = a.client_id,
		access = d.access_token,
		-- Paper may hand back a new refresh token, or keep the old one.
		refresh = d.refresh_token or a.refresh,
		expires = os.time() + (tonumber(d.expires_in) or 300),
	})
end

local function signed_out()
	local a = auth:get()
	auth:set({ client_id = a.client_id })
end

-- One try at the device code: true once signed in.
local function poll_once(): boolean
	local p = pending
	if not p then
		return false
	end
	if os.time() >= p.expires then
		pending = nil
		return false
	end
	local status, d = post_form("/oauth2/token", {
		grant_type = "urn:ietf:params:oauth:grant-type:device_code",
		device_code = p.device_code,
		client_id = client_id(),
		resource = RESOURCE,
	})
	if status < 300 and type(d) == "table" and d.access_token then
		keep(d)
		if pending == p then
			pending = nil
		end
		print("signed in to Paper")
		return true
	end
	local why = if type(d) == "table" then d.error else nil
	if why == "slow_down" then
		p.interval += 5
	elseif why ~= "authorization_pending" then
		if pending == p then
			pending = nil
		end
	end
	return false
end

-- A sign-in code for the person, the one already waiting when there is one.
local function start_signin(): Pending
	local p = pending
	if p and os.time() < p.expires - 15 then
		return p
	end
	local status, d = post_form("/oauth2/device_authorization", {
		client_id = client_id(),
		scope = "openid offline_access",
		resource = RESOURCE,
	})
	if status >= 300 or type(d) ~= "table" or type(d.device_code) ~= "string" then
		error(`Paper didn't give a sign-in code (HTTP {status})`, 0)
	end
	local fresh: Pending = {
		device_code = d.device_code,
		code = d.user_code,
		url = d.verification_uri_complete or d.verification_uri,
		expires = os.time() + (tonumber(d.expires_in) or 300),
		interval = tonumber(d.interval) or 5,
	}
	pending = fresh
	zeron.task(function()
		while pending == fresh and os.time() < fresh.expires do
			zeron.sleep(fresh.interval):await()
			if pending ~= fresh then
				return
			end
			local ok, done = pcall(poll_once)
			if ok and done then
				return
			end
		end
	end)
	return fresh
end

local refreshing = false

-- A live access token, refreshed when it's about to end. nil: not signed in.
local function token(force: boolean?): string?
	local waited = 0
	while refreshing and waited < 30 do
		zeron.sleep(0.1):await()
		waited += 0.1
	end
	local a = auth:get()
	if not force and type(a.access) == "string" and (a.expires or 0) - 30 > os.time() then
		return a.access
	end
	if type(a.refresh) ~= "string" then
		if pending and poll_once() then
			return auth:get().access
		end
		return nil
	end
	refreshing = true
	local ok, status, d = pcall(post_form, "/oauth2/token", {
		grant_type = "refresh_token",
		refresh_token = a.refresh,
		client_id = a.client_id or client_id(),
		resource = RESOURCE,
	})
	refreshing = false
	if not ok then
		error(`Paper's sign-in server didn't answer: {status}`, 0)
	end
	if status < 300 and type(d) == "table" and d.access_token then
		keep(d)
		return d.access_token
	end
	local why = if type(d) == "table" then d.error else nil
	if why == "invalid_grant" or why == "invalid_client" or status == 401 then
		print(`Paper sign-in ended: {why or status}`)
		signed_out()
		return nil
	end
	error(`Paper's sign-in server answered HTTP {status}`, 0)
end

local function not_signed_in()
	local p = start_signin()
	error(
		`Paper isn't signed in on this device. Ask the person to open {p.url} and approve code {p.code}, then call again.`,
		0
	)
end

-- The MCP session with Paper: its id and the instructions Paper gave.
local session: { id: string?, instructions: any }? = nil
local next_id = 0

-- One JSON-RPC message out of a reply that may be JSON or an event stream.
local function reply_of(r: any, id: number?): any
	local kind = header(r.headers, "content-type") or ""
	if string.find(kind, "text/event-stream", 1, true) then
		local found = nil
		for event in string.gmatch((r.body or "") .. "\n\n", "(.-)\r?\n\r?\n") do
			local data = {}
			for line in string.gmatch(event, "[^\r\n]+") do
				local v = string.match(line, "^data: ?(.*)$")
				if v then
					table.insert(data, v)
				end
			end
			local m = decode(table.concat(data, "\n"))
			if type(m) == "table" and (id == nil or m.id == id) and (m.result ~= nil or m.error ~= nil) then
				found = m
			end
		end
		return found
	end
	return decode(r.body)
end

-- A JSON-RPC message, written out here so an empty object stays `{}`
-- (a Lua table can't say whether it's an object or a list).
local function message(id: number?, method: string, params: string?): string
	local idp = if id then `"id":{id},` else ""
	local pp = if params then `,"params":{params}` else ""
	return `\{"jsonrpc":"2.0",{idp}"method":{zeron.json.encode(method)}{pp}\}`
end

-- A table as a JSON object: `{}` when it's empty.
local function object(t: any): string
	if type(t) ~= "table" or next(t) == nil then
		return "{}"
	end
	return zeron.json.encode(t)
end

local function send(bearer: string, body: string, sid: string?): any
	local headers: { [string]: string } = {
		authorization = "Bearer " .. bearer,
		["content-type"] = "application/json",
		accept = "application/json, text/event-stream",
		["mcp-protocol-version"] = PROTOCOL,
	}
	if sid then
		headers["mcp-session-id"] = sid
	end
	return zeron.fetch(MCP, { method = "POST", headers = headers, body = body, timeout = 120 }):await()
end

local function open(bearer: string): (number, any)
	next_id += 1
	local id = next_id
	local client = zeron.json.encode({ name = "zeron-paper", version = VERSION })
	local r = send(bearer, message(id, "initialize", `\{"protocolVersion":"{PROTOCOL}","capabilities":\{\},"clientInfo":{client}\}`))
	if r.status >= 300 then
		return r.status, nil
	end
	local m = reply_of(r, id)
	local sid = header(r.headers, "mcp-session-id")
	session = { id = sid, instructions = if type(m) == "table" and m.result then m.result.instructions else nil }
	send(bearer, message(nil, "notifications/initialized"), sid)
	return r.status, session
end

-- A request to Paper's server: its result, or an error saying why not.
local function rpc(method: string, params: string?): any
	local tries = 0
	local force = false
	while true do
		tries += 1
		local bearer = token(force)
		if not bearer then
			not_signed_in()
			return nil
		end
		local status = 200
		if not session then
			status = open(bearer)
		end
		if session then
			next_id += 1
			local id = next_id
			local r = send(bearer, message(id, method, params), session.id)
			status = r.status
			if status < 300 then
				local m = reply_of(r, id)
				if type(m) ~= "table" then
					error(`Paper's server gave no answer to {method}`, 0)
				end
				if m.error then
					error(`Paper: {m.error.message or zeron.json.encode(m.error)}`, 0)
				end
				return m.result
			end
		end
		-- Signed out by Paper: refresh once. An ended session: start anew once.
		if tries >= 3 then
			error(`Paper's server answered HTTP {status}`, 0)
		end
		if status == 401 then
			session = nil
			force = true
		elseif status == 404 or status == 400 then
			session = nil
			force = false
		else
			error(`Paper's server answered HTTP {status}`, 0)
		end
	end
end

zeron.tool {
	name = "list_tools",
	run = function(_args: any)
		local tools = {}
		local cursor: string? = nil
		repeat
			local result = rpc("tools/list", if cursor then `\{"cursor":{zeron.json.encode(cursor)}\}` else nil)
			for _, t in (result and result.tools) or {} do
				table.insert(tools, t)
			end
			cursor = result and result.nextCursor
		until not cursor
		return {
			instructions = session and session.instructions,
			tools = tools,
		}
	end,
}

-- Paper's images (a screenshot) as files: a tool's result reaches agents as
-- text, where an image would be base64 that no agent can see. Each is
-- written out with openssl (base64 in, as stdin carries only text) and its
-- block says where. One openssl can't write stays as Paper sent it.
local EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/webp"] = "webp", ["image/gif"] = "gif" }
local saved = 0
local function pictures(result: any): any
	if type(result) ~= "table" or type(result.content) ~= "table" then
		return result
	end
	for i, block in result.content do
		if type(block) == "table" and block.type == "image" and type(block.data) == "string" then
			saved += 1
			local kind = if type(block.mimeType) == "string" then block.mimeType else "image/png"
			local path = `/tmp/paper-{os.time()}-{saved}.{EXT[kind] or "png"}`
			local ok, r = pcall(function()
				return zeron.run("openssl", { "base64", "-d", "-A", "-out", path }, { stdin = block.data, timeout = 30 }):await()
			end)
			if ok and type(r) == "table" and r.status == 0 then
				result.content[i] = { type = "text", text = `Paper's image ({kind}) is saved at {path}. Open that file to see it.` }
			end
		end
	end
	return result
end

zeron.tool {
	name = "call_tool",
	run = function(args: any)
		if type(args) ~= "table" or type(args.name) ~= "string" or args.name == "" then
			error("name is required: a tool name from list_tools", 0)
		end
		return pictures(rpc("tools/call", `\{"name":{zeron.json.encode(args.name)},"arguments":{object(args.arguments)}\}`))
	end,
}

-- For the Paper tab: whether agents here are signed in, and a code when not.
zeron.serve("status", function()
	local a = auth:get()
	local p = pending
	return {
		signed_in = type(a.refresh) == "string" or (type(a.access) == "string" and (a.expires or 0) > os.time()),
		code = p and p.code,
		url = p and p.url,
	}
end, { safe = true })

zeron.serve("signin", function()
	local p = start_signin()
	return { code = p.code, url = p.url }
end)

zeron.serve("cancel", function()
	pending = nil
	local a = auth:get()
	return { signed_in = type(a.refresh) == "string" }
end)

zeron.serve("signout", function()
	session = nil
	pending = nil
	signed_out()
	return { signed_in = false }
end)

-- A Paper file's link as paper.json keeps it: the file's address alone
-- (no page, no query). nil: not a Paper file.
local function file_link(url: any): string?
	if type(url) ~= "string" then
		return nil
	end
	local id = string.match(url, "^https://app%.paper%.design/file/([%w_%-]+)")
	return if id then `https://app.paper.design/file/{id}` else nil
end

-- A folder's paper.json: whether there is one, and what it says (nil when
-- it isn't JSON).
local function read_links(dir: string): (boolean, any)
	local r = zeron.run("cat", { dir .. "/paper.json" }, { timeout = 5 }):await()
	if r.status ~= 0 then
		return false, nil
	end
	return true, decode(r.stdout)
end

local function folder(dir: any): string?
	if type(dir) == "string" and string.sub(dir, 1, 1) == "/" and not string.find(dir, "/../", 1, true) then
		return dir
	end
	return nil
end

-- The designs a checkout links in its paper.json, as { name, url }: its
-- own, else its project's (a worktree without one).
zeron.serve("designs", function(args: any)
	local out = {}
	for _, dir in { folder(args and args.cwd) or false, folder(args and args.root) or false } do
		if dir and #out == 0 then
			local _, d = read_links(dir)
			for _, f in (type(d) == "table" and type(d.files) == "table" and d.files) or {} do
				if type(f) == "table" and type(f.url) == "string" and string.match(f.url, "^https://app%.paper%.design/") then
					table.insert(out, { name = if type(f.name) == "string" and f.name ~= "" then f.name else "Design", url = f.url })
				end
			end
		end
	end
	return { files = out }
end, { safe = true })

-- paper.json written out for people to read: two spaces in, a file a line.
local function written(d: { [string]: any }): string
	local files = {}
	for _, f in d.files do
		if type(f) == "table" and type(f.name) == "string" and type(f.url) == "string" then
			table.insert(files, `    \{ "name": {zeron.json.encode(f.name)}, "url": {zeron.json.encode(f.url)} \}`)
		else
			table.insert(files, "    " .. zeron.json.encode(f))
		end
	end
	local parts = { `  "files": [\n{table.concat(files, ",\n")}\n  ]` }
	local keys = {}
	for k in d do
		if k ~= "files" then
			table.insert(keys, tostring(k))
		end
	end
	table.sort(keys)
	for _, k in keys do
		table.insert(parts, `  {zeron.json.encode(k)}: {zeron.json.encode(d[k])}`)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n}\n"
end

-- A design linked in the checkout's paper.json (made from the project's
-- when the checkout has none of its own). Linked already: left as it is.
zeron.serve("link", function(args: any)
	local url = file_link(args and args.url)
	if not url then
		error("That isn't a Paper file's link.", 0)
	end
	local cwd = folder(args.cwd)
	if not cwd then
		error("This chat has no folder to link it in.", 0)
	end
	local here, d = read_links(cwd)
	if here and type(d) ~= "table" then
		error("This checkout's paper.json isn't valid JSON. Fix it, then link again.", 0)
	end
	local root = folder(args.root)
	if not here and root and root ~= cwd then
		local there, theirs = read_links(root)
		if there and type(theirs) == "table" then
			d = theirs
		end
	end
	local links: { [string]: any } = if type(d) == "table" then d else {}
	if type(links.files) ~= "table" then
		links.files = {}
	end
	for _, f in links.files do
		if type(f) == "table" and file_link(f.url) == url then
			return { linked = false, url = url }
		end
	end
	local name = if type(args.name) == "string" and args.name ~= "" then string.sub(args.name, 1, 120) else "Design"
	table.insert(links.files, { name = name, url = url })
	local r = zeron.run("tee", { cwd .. "/paper.json" }, { stdin = written(links), timeout = 5 }):await()
	if r.status ~= 0 then
		error(`Couldn't write paper.json: {r.stderr}`, 0)
	end
	return { linked = true, url = url }
end)
