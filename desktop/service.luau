-- Desktop's service: on the device a chat runs on, how the agents' desktop
-- stands and its sign-in link, read from its systemd user units
-- (agent-desktop.target: Xvfb, XFCE, Fortress, voxl), and starting it.
-- The units are made by ~/.local/share/agent-desktop/desktop.sh install.
--
--   status  -> { installed, running = { part = bool }, ready, url? }
--   start   -> the same, after starting agent-desktop.target

local zeron = require("./zeron")("desktop")

local PARTS = { "x", "session", "browser", "stream" }

local function systemctl(args: { string }): any
	local full = { "--user" }
	for _, a in args do
		table.insert(full, a)
	end
	return zeron.run("systemctl", full, { timeout = 30 }):await()
end

-- `systemctl show` prints blocks of KEY=value lines, one block per unit.
local function units(): { [string]: { [string]: string } }
	local names = {}
	for _, p in PARTS do
		table.insert(names, `agent-desktop-{p}.service`)
	end
	local args = { "show", "-p", "Id", "-p", "ActiveState", "-p", "LoadState", "-p", "Environment" }
	for _, n in names do
		table.insert(args, n)
	end
	local r = systemctl(args)
	local out: { [string]: { [string]: string } } = {}
	local cur: { [string]: string } = {}
	for line in string.gmatch(r.stdout .. "\n\n", "([^\n]*)\n") do
		if line == "" then
			if cur.Id then
				out[cur.Id] = cur
			end
			cur = {}
		else
			local k, v = string.match(line, "^([^=]+)=(.*)$")
			if k then
				cur[k] = v
			end
		end
	end
	return out
end

-- A variable's value in systemd's Environment= line (entries may be quoted).
local function env_value(environment: string?, name: string): string?
	if not environment then
		return nil
	end
	local v = string.match(environment, '"' .. name .. '=([^"]*)"') or string.match(environment, name .. "=(%S+)")
	if v == nil or v == "" then
		return nil
	end
	return v
end

local function status(call: any): any
	local u = units()
	local running = {}
	local installed, ready = true, true
	for _, p in PARTS do
		local unit = u[`agent-desktop-{p}.service`]
		if not unit or unit.LoadState ~= "loaded" then
			installed = false
		end
		local up = unit ~= nil and unit.ActiveState == "active"
		running[p] = up
		ready = ready and up
	end
	local stream = u["agent-desktop-stream.service"]
	local env = stream and stream.Environment
	-- A window on this device opens voxl directly; any other through the tailnet's HTTPS.
	local here = call and call.from and call.from.id == zeron.device.id
	local url = if here
		then env_value(env, "AGENT_DESKTOP_LOCAL_URL")
		else env_value(env, "AGENT_DESKTOP_URL")
	return { installed = installed, running = running, ready = ready, url = url, device = zeron.device.name }
end

zeron.serve("status", function(_args, call)
	return status(call)
end, { safe = true })

zeron.serve("start", function(_args, call)
	local r = systemctl({ "start", "agent-desktop.target" })
	if r.status ~= 0 then
		error(if r.stderr ~= "" then r.stderr else "systemctl start failed", 0)
	end
	-- The parts come up within a few seconds; answer once they're active.
	for _ = 1, 10 do
		local s = status(call)
		if s.ready then
			return s
		end
		zeron.sleep(1):await()
	end
	return status(call)
end, { safe = true })
