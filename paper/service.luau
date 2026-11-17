--!strict
-- Paper for the chat's panel. Agents reach Paper through its own MCP server
-- (mcp.paper.design), set up in each agent harness on the device with its own
-- sign-in, so Paper works the same inside Zeron and out. This service only
-- reads where each harness stands with Paper, and keeps the checkout's
-- paper.json: the designs it lists and the ones New design links.

local zeron = require("./zeron")("paper")

local MCP = "https://mcp.paper.design/"
local VERSION = "0.2.0"

local function decode(body: string?): any
	if type(body) ~= "string" or body == "" then
		return nil
	end
	local ok, v = pcall(zeron.json.decode, body)
	return if ok then v else nil
end

-- A program, run as the person; nil when it can't be run here (not
-- installed, or not on the PATH Zeron runs programs with).
local function run(program: string, args: { string }): any
	local ok, r = pcall(function()
		return zeron.run(program, args, { timeout = 30 }):await()
	end)
	if not ok or type(r) ~= "table" or r.status == 127 then
		return nil
	end
	return r
end

-- Each harness: how it says where Paper stands ("in" signed in, "out" set up
-- but not signed in, "missing" not set up, "error" set up and failing), and
-- the commands that set it up and sign in.
type Harness = {
	id: string,
	name: string,
	mark: string,
	check: () -> ...any,
	setup: string,
	login: string,
}

local HARNESSES: { Harness } = {
	{
		id = "claude",
		name = "Claude Code",
		mark = "claude",
		check = function()
			local r = run("claude", { "mcp", "get", "paper" })
			if not r then
				return nil
			end
			local out = (r.stdout or "") .. (r.stderr or "")
			if r.status ~= 0 then
				return if string.find(out, "No MCP server", 1, true) then "missing" else "error", out
			end
			if string.find(out, "Connected", 1, true) then
				return "in"
			elseif string.find(out, "authenticat", 1, true) then
				return "out"
			end
			return "error", string.match(out, "Status:%s*([^\n]+)")
		end,
		setup = `claude mcp add --transport http --scope user paper {MCP} && claude mcp login paper`,
		login = "claude mcp login paper",
	},
	{
		id = "codex",
		name = "Codex",
		mark = "openai",
		check = function()
			local r = run("codex", { "mcp", "list", "--json" })
			if not r then
				return nil
			end
			local list = decode(r.stdout)
			if type(list) ~= "table" then
				return "error", r.stderr
			end
			for _, s in list do
				if type(s) == "table" and s.name == "paper" then
					if s.enabled == false then
						return "error", s.disabled_reason or "turned off"
					elseif s.auth_status == "not_logged_in" then
						return "out"
					end
					return "in"
				end
			end
			return "missing"
		end,
		-- (Codex signs in as it adds a server.)
		setup = `codex mcp add paper --url {MCP}`,
		login = "codex mcp login paper",
	},
	{
		id = "pi",
		name = "Pi",
		mark = "pi",
		check = function()
			-- (Pi exits 1 when any server fails; what it prints still says.)
			local r = run("pi", { "mcp", "list", "--json" })
			if not r then
				return nil
			end
			local d = decode(r.stdout)
			if type(d) ~= "table" or type(d.servers) ~= "table" then
				return "error", r.stderr
			end
			for _, s in d.servers do
				if type(s) == "table" and s.name == "paper" then
					if s.state == "needs-auth" then
						return "out"
					elseif s.enabled == false then
						return "error", "turned off"
					elseif type(s.tools) == "table" and #s.tools > 0 then
						return "in"
					end
					return "error", if type(s.error) == "string" then s.error else s.state
				end
			end
			return "missing"
		end,
		setup = `pi mcp add paper --url {MCP} && pi mcp login paper`,
		login = "pi mcp login paper",
	},
}

-- For the Paper tab: each harness on this device and where it stands with
-- Paper, with the command that gets it the rest of the way. A harness that
-- isn't installed here isn't listed.
zeron.serve("agents", function()
	local out = {}
	for _, h in HARNESSES do
		local state, why = h.check()
		if state then
			table.insert(out, {
				id = h.id,
				name = h.name,
				mark = h.mark,
				state = state,
				why = if type(why) == "string" and why ~= "" then string.sub(why, 1, 200) else nil,
				command = if state == "missing" then h.setup elseif state == "in" then nil else h.login,
			})
		end
	end
	return { agents = out, version = VERSION }
end, { safe = true })

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
