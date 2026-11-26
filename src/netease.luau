--!strict

local netease = {}

export type Caps = {
	play: boolean,
	next: boolean,
	prev: boolean,
	volume: boolean,
	volume_up: boolean,
	volume_down: boolean,
	mute: boolean,
}

export type Player = {
	backend: string,
	beat: number,
	seq: number,
	running: boolean,
	status: string,
	title: string,
	artist: string,
	track: string,
	album: string?,
	duration: number?,
	art_url: string?,
	pos_seq: number,
	volume: number?,
	muted: boolean?,
	can: Caps,
	ack: string?,
	error: string?,
	problem: string?,
}

local DATA = tern.plugin.data
local SEP = if string.find(tern.plugin.dir, "\\", 1, true) then "\\" else "/"
local STATE = DATA .. SEP .. "state.txt"
local LEASE = DATA .. SEP .. "lease"
local CMD = DATA .. SEP .. "cmd"
local LOG = DATA .. SEP .. "helper.log"

local STALE_S = 6
local LEASE_EVERY_S = 10
local RESPAWN_AFTER_S = 15

local function path(...: string): string
	return table.concat({ tern.plugin.dir, ... }, SEP)
end

local function str(raw: string?): string?
	return if raw == nil or raw == "" then nil else raw
end

local function num(raw: string?): number?
	return if raw == nil or raw == "" then nil else tonumber(raw)
end

local function flag(raw: string?): boolean?
	if raw == "1" then
		return true
	elseif raw == "0" then
		return false
	end
	return nil
end

function netease.parse(text: string): Player?
	local fields: { [string]: string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local key, value = string.match(line, "^([%w_]+)=(.*)$")
		if key and value then
			fields[key] = (string.gsub(value, "\r$", ""))
		end
	end
	if fields.v ~= "1" then
		return nil
	end
	return {
		backend = fields.backend or "?",
		beat = num(fields.beat) or 0,
		seq = num(fields.seq) or 0,
		running = fields.running == "1",
		status = fields.status or "",
		title = fields.title or "",
		artist = fields.artist or "",
		track = fields.track_id or "",
		pos_seq = num(fields.pos_seq) or 0,
		volume = num(fields.volume),
		muted = flag(fields.muted),
		can = {
			play = fields.can_play == "1",
			next = fields.can_next == "1",
			prev = fields.can_prev == "1",
			volume = fields.can_volume == "1",
			volume_up = fields.can_volume_up == "1",
			volume_down = fields.can_volume_down == "1",
			mute = fields.can_mute == "1",
		},
		ack = str(fields.ack),
		error = str(fields.error),
		problem = str(fields.problem),
	}
end

function netease.read(): Player?
	local ok, text = pcall(tern.fs.read, STATE, 64 * 1024)
	if not ok then
		return nil
	end
	return netease.parse(text)
end

function netease.is_fresh(player: Player?): boolean
	return player ~= nil and os.time() - player.beat <= STALE_S
end

type Track = { title: string, artist: string, album: string?, duration: number?, art_url: string? }
type TrackLookup = { id: string, retry_at: number, result: Track? }
local lookup: TrackLookup? = nil

function netease.mac_node(): string
	for directory in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		if string.sub(directory, 1, 1) == "/" then
			local candidate = directory .. "/node"
			if tern.fs.exists(candidate) then
				return candidate
			end
		end
	end
	-- Tern may be launched outside the shell's Homebrew environment.
	for _, candidate in { "/opt/homebrew/bin/node", "/usr/local/bin/node" } do
		if tern.fs.exists(candidate) then
			return candidate
		end
	end
	return "node"
end

function netease.resolve_track(player: Player)
	if player.backend ~= "macos" or not player.running or not netease.is_fresh(player)
		or not string.match(player.track, "^[1-9]%d*$") then
		return
	end
	local pending = lookup
	if pending and pending.id == player.track and pending.result then
		local track = pending.result
		player.title = track.title
		player.artist = track.artist
		player.album = track.album
		player.duration = track.duration
		player.art_url = track.art_url
		return
	end
	local now = os.time()
	if pending and pending.id == player.track and now < pending.retry_at then
		return
	end
	local next_lookup: TrackLookup = { id = player.track, retry_at = now + 3, result = nil }
	lookup = next_lookup
	pcall(
		tern.process.run,
		{ netease.mac_node(), tern.plugin.dir .. "/helpers/macos/track.mjs", next_lookup.id },
		{ timeout_ms = 2000 },
		function(result: ProcessResult, _)
			if lookup ~= next_lookup or result.status ~= 0 then
				return
			end
			local ok, data = pcall(tern.json.decode, result.stdout)
			if ok and type(data) == "table" and data.id == next_lookup.id
				and type(data.title) == "string" and data.title ~= "" then
				next_lookup.result = {
					title = data.title,
					artist = if type(data.artist) == "string" then data.artist else "",
					album = if type(data.album) == "string" then data.album else nil,
					duration = if type(data.duration) == "number" then data.duration else nil,
					art_url = if type(data.art_url) == "string" then data.art_url else nil,
				}
			end
		end
	)
end

local spawned_at = -math.huge
local leased_at = -math.huge
local spawn_problem: string? = nil

local function helper_argv(): ({ string }?, string?)
	local os_name = tern.runtime.os
	if os_name == "windows" then
		local root = tern.getenv("SystemRoot") or "C:\\Windows"
		local wscript = root .. "\\System32\\wscript.exe"
		local ps = root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
		local script = { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path("helpers", "windows", "netease.ps1"), "-Data", DATA }
		local argv: { string }
		if tern.fs.exists(wscript) then
			-- Started directly powershell.exe opens a terminal window.
			argv = { wscript, "//B", "//Nologo", path("helpers", "windows", "launch-hidden.js"), ps }
		else
			argv = { ps, "-WindowStyle", "Hidden" }
		end
		for _, part in script do
			table.insert(argv, part)
		end
		return argv, nil
	end
	if os_name == "macos" then
		local helper = path("helpers", "macos", "netease-helper")
		if not tern.fs.exists(helper) then
			return nil, "The macOS helper is missing. Build the plugin package using helpers/macos/build.sh."
		end
		return { helper, "serve", DATA }, nil
	end
	return nil, "NetEase control isn't available on " .. os_name .. "."
end

local function log_tail(): string?
	local ok, text = pcall(tern.fs.read, LOG, 256 * 1024)
	if not ok or text == "" then
		return nil
	end
	local lines = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(lines, line)
	end
	return table.concat(lines, "\n", math.max(1, #lines - 2))
end

function netease.ensure(player: Player?): string?
	local now = os.time()
	if now - leased_at >= LEASE_EVERY_S then
		if pcall(tern.fs.write, LEASE, tostring(now) .. "\n") then
			leased_at = now
		end
	end
	if netease.is_fresh(player) or now - spawned_at < RESPAWN_AFTER_S then
		return spawn_problem
	end
	local argv, why = helper_argv()
	if not argv then
		spawn_problem = why
		return why
	end
	spawned_at = now
	local ok, err = pcall(function()
		tern.process.run(argv, {}, function(result: ProcessResult, _)
			if result.status ~= 0 and os.time() - spawned_at < 5 then
				local detail = log_tail() or (result.stderr ~= "" and result.stderr) or nil
				spawn_problem = "The NetEase helper stopped (exit " .. tostring(result.status) .. ")."
					.. (if detail then "\n" .. detail else "")
			end
		end)
	end)
	spawn_problem = if ok then nil else "Could not start the NetEase helper: " .. tostring(err)
	return spawn_problem
end

function netease.retry()
	spawn_problem = nil
	spawned_at = -math.huge
end

local counter = 0

function netease.send(name: string, arg: (string | number)?): string
	counter += 1
	local id = string.format("%d-%06d-%05d", os.time(), counter, math.random(0, 99999))
	pcall(tern.fs.mkdir, DATA)
	pcall(tern.fs.mkdir, CMD)
	local text = name .. "\n" .. (if arg ~= nil then tostring(arg) else "") .. "\n"
	tern.fs.write(CMD .. SEP .. id .. ".cmd", text)
	netease.ensure(netease.read())
	return id
end

function netease.clock(ms: number?): string
	if ms == nil then
		return "-:--"
	end
	local total_seconds = math.max(0, ms // 1000)
	if total_seconds >= 3600 then
		return string.format("%d:%02d:%02d", total_seconds // 3600, (total_seconds // 60) % 60, total_seconds % 60)
	end
	return string.format("%d:%02d", total_seconds // 60, total_seconds % 60)
end

function netease.cut(text: string, width: number): string
	local length = utf8.len(text)
	if length == nil or length <= width then
		return text
	end
	local stop = utf8.offset(text, width) or #text
	return string.sub(text, 1, stop - 1) .. "…"
end

return netease
