-- Delirium CarClaim - the server side: claims, access lists, the login timer
-- and the one-time import of VehicleClaimWG claims.
--
-- The client only asks; the server checks distance, rights and limits and
-- changes the state, then sends the whole table to every client.
--
-- media/lua/server/ is also executed by connected clients, hence the guard
-- (see E:\mods\CLAUDE.md).

if isClient() then return end

require "DCC_Shared"

local M = DelCarClaim
local MODULE = M.MODULE
local STATE_KEY = M.STATE_KEY
-- Last time each player was online (os.time() of the server). Server only:
-- never transmitted, never compared with a client's clock.
local SEEN_KEY = "DelCarClaim_Seen"
local DAY = 24 * 60 * 60

local Commands = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(msg)
	print("[DelCarClaim] " .. msg)
	writeLog("DelCarClaim", msg)
end

local function now()
	return math.floor(os.time())
end

local function state()
	local s = ModData.getOrCreate(STATE_KEY)
	if type(s.cars) ~= "table" then s.cars = {} end
	return s
end

local function seen()
	return ModData.getOrCreate(SEEN_KEY)
end

local function transmit()
	ModData.transmit(STATE_KEY)
end

-- The client turns the key into text in its own language.
local function notify(player, key, arg1, arg2)
	sendServerCommand(player, MODULE, "notify", { key = key, arg1 = arg1, arg2 = arg2 })
end

local function whose(entry)
	if entry.hall then return "hall " .. tostring(entry.hall) end
	return tostring(entry.owner)
end

local function describe(uid, entry)
	return string.format("%s %s (%s) at %s,%s", uid, tostring(entry.name), whose(entry), tostring(entry.x), tostring(entry.y))
end

-- A fresh id for a car claimed for the first time. Time plus a random part,
-- not a counter: a car saved with its id after the last world save would
-- otherwise share it with the next one claimed after a rollback.
local function newUid(s)
	for _ = 1, 20 do
		local uid = string.format("DCC-%.0f-%04d", os.time(), ZombRand(10000))
		if not s.cars[uid] then return uid end
	end
	return nil
end

local function vehicleFromArgs(args)
	local id = tonumber(args.vehicle)
	if not id then return nil end
	return getVehicleById(id)
end

local function near(player, vehicle)
	local dx = player:getX() - vehicle:getX()
	local dy = player:getY() - vehicle:getY()
	return dx * dx + dy * dy <= M.CLAIM_DISTANCE * M.CLAIM_DISTANCE
end

local function remember(entry, vehicle)
	entry.name = vehicle:getScript():getName()
	entry.x = math.floor(vehicle:getX())
	entry.y = math.floor(vehicle:getY())
	entry.z = math.floor(vehicle:getZ())
end

local function entryFromArgs(args)
	if type(args.uid) ~= "string" then return nil, nil end
	return state().cars[args.uid], args.uid
end

-- ---------------------------------------------------------------------------
-- The login timer
-- ---------------------------------------------------------------------------

local function onlinePlayers()
	local out = {}
	local players = getOnlinePlayers()
	if not players then return out end
	for i = 0, players:size() - 1 do
		local player = players:get(i)
		if player then table.insert(out, player) end
	end
	return out
end

local function touchOnline()
	local sn = seen()
	local t = now()
	for _, player in ipairs(onlinePlayers()) do
		sn[player:getUsername()] = t
	end
end
Events.EveryOneMinute.Add(touchOnline)

-- Last login of a player. Someone the mod has never seen (it was just
-- installed, or they have not logged in since) starts counting now.
local function lastSeen(sn, username, t)
	if not username then return nil end
	local value = tonumber(sn[username])
	if not value then
		sn[username] = t
		return t
	end
	return value
end

-- Latest login of the head and staff of an organization; nil if it has none.
local function hallLastSeen(sn, hall, t)
	local best = lastSeen(sn, hall.mayor, t)
	if type(hall.staff) == "table" then
		for username, _ in pairs(hall.staff) do
			local value = lastSeen(sn, username, t)
			if value and (not best or value > best) then best = value end
		end
	end
	return best
end

-- Why a claim ends now, or nil.
local function expiry(entry, econ, sn, t, days)
	if entry.hall then
		-- The Economy state not loaded yet: say nothing about its halls.
		if not econ or type(econ.halls) ~= "table" then return nil end
		local hall = econ.halls[entry.hall]
		if not hall then return "organization deleted" end
		if days <= 0 then return nil end
		local last = hallLastSeen(sn, hall, t)
		if last and t - last > days * DAY then
			return string.format("nobody of the organization online for %.1f days", (t - last) / DAY)
		end
		return nil
	end
	if days <= 0 or not entry.owner then return nil end
	local last = lastSeen(sn, entry.owner, t)
	if t - last > days * DAY then
		return string.format("owner offline for %.1f days", (t - last) / DAY)
	end
	return nil
end

local function checkExpiry()
	local s = state()
	local econ = DelEcon.getState()
	local sn = seen()
	local t = now()
	local days = M.inactivityDays()
	local gone = {}
	for uid, entry in pairs(s.cars) do
		local reason = expiry(entry, econ, sn, t, days)
		if reason then table.insert(gone, { uid = uid, reason = reason }) end
	end
	for _, item in ipairs(gone) do
		log("Released " .. describe(item.uid, s.cars[item.uid]) .. ": " .. item.reason)
		s.cars[item.uid] = nil
	end
	return #gone > 0
end

-- ---------------------------------------------------------------------------
-- Loaded cars: position for the lists, wrecks, VehicleClaimWG leftovers
-- ---------------------------------------------------------------------------

-- A car imported from VehicleClaimWG, seen for the first time: that mod kept
-- the owner and the access list on the car, the list it saved was only a
-- copy. The car decides: free there means free here, its owner and access
-- list are taken over. Done once per car (the wg flag goes).
local function adoptOld(uid, entry, vehicle)
	local data = vehicle:getModData()
	local owner = data.WG_Claim_Owner or data.owner
	entry.wg = nil
	if type(owner) ~= "string" or owner == "" then return "free in VehicleClaimWG" end
	if owner ~= entry.owner then
		log(string.format("Import %s: owner %s -> %s (as on the car)", uid, tostring(entry.owner), owner))
		entry.owner = owner
	end
	entry.allowed = entry.allowed or {}
	if type(data.allowed) == "table" then
		for _, name in pairs(data.allowed) do
			if type(name) == "string" and name ~= "" then entry.allowed[name] = true end
		end
	end
	return nil
end

-- getCell():getVehicles() is a java.util.Set: toArray() + ipairs
-- (see claude/Delirium-Zones-Vehicles.md).
local function scanLoaded()
	local cell = getCell()
	local set = cell and cell:getVehicles()
	if not set then return false end
	local s = state()
	local changed = false
	for _, vehicle in ipairs(set:toArray()) do
		local entry, uid = M.entryOf(s, vehicle)
		if entry then
			local reason = nil
			if entry.wg then
				reason = adoptOld(uid, entry, vehicle)
				changed = true
			end
			if not reason and M.isWreck(vehicle) then reason = "wreck" end
			if reason then
				log("Released " .. describe(uid, entry) .. ": " .. reason)
				s.cars[uid] = nil
				changed = true
			else
				local x, y = math.floor(vehicle:getX()), math.floor(vehicle:getY())
				if x ~= entry.x or y ~= entry.y then
					remember(entry, vehicle)
					changed = true
				end
			end
		end
	end
	return changed
end

local function everyHour()
	local changed = checkExpiry()
	if scanLoaded() then changed = true end
	if changed then transmit() end
end
Events.EveryHours.Add(everyHour)

-- ---------------------------------------------------------------------------
-- Import from VehicleClaimWG (once). Its global ModData stays in the save
-- after the mod is switched off. Claims it was about to drop (its pending
-- list) are skipped; the access lists come later, from the cars themselves.
-- Everybody's timer starts at the import.
-- ---------------------------------------------------------------------------

local function importOld(s)
	if s.imported then return end
	s.imported = true
	local old = ModData.get("VehicleClaimWG_List")
	if type(old) ~= "table" then
		log("Import: no VehicleClaimWG claims in this save")
		return
	end
	local pending = ModData.get("VehicleClaimWG_PendingUnclaims")
	if type(pending) ~= "table" then pending = {} end
	local count, skipped = 0, 0
	for user, list in pairs(old) do
		if type(list) == "table" then
			for id, row in pairs(list) do
				local uid = tostring(id)
				if string.sub(uid, 1, 3) ~= "WG-" or pending[uid] or s.cars[uid] then
					skipped = skipped + 1
				else
					row = type(row) == "table" and row or {}
					s.cars[uid] = { owner = tostring(user), by = tostring(user), allowed = {}, name = row.name or "?",
						x = tonumber(row.x), y = tonumber(row.y), z = tonumber(row.z), wg = true }
					count = count + 1
				end
			end
		end
	end
	log(string.format("Import: %d claims taken over from VehicleClaimWG, %d skipped", count, skipped))
end

local function onInitGlobalModData()
	local s = state()
	importOld(s)
	-- B42 ids may come with a leading backslash ("\VehicleClaimWG").
	local mods = getActivatedMods()
	for i = 0, mods:size() - 1 do
		if string.find(tostring(mods:get(i)), "VehicleClaimWG", 1, true) then
			log("WARNING: VehicleClaimWG is enabled too - switch it off, the two mods lock cars differently")
		end
	end
end
Events.OnInitGlobalModData.Add(onInitGlobalModData)

-- Delirium Economy calls this when an organization is deleted (the hourly
-- check would catch it too, this is just sooner).
DelEcon.hallDeletedHooks = DelEcon.hallDeletedHooks or {}
table.insert(DelEcon.hallDeletedHooks, function(hallId)
	local s = state()
	local gone = {}
	for uid, entry in pairs(s.cars) do
		if entry.hall == hallId then table.insert(gone, uid) end
	end
	for _, uid in ipairs(gone) do
		log("Released " .. describe(uid, s.cars[uid]) .. ": organization deleted")
		s.cars[uid] = nil
	end
	if #gone > 0 then transmit() end
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- args.vehicle = vehicle:getId(); args.hall = organization id for an
-- organization's car, absent for a personal one.
function Commands.claim(player, args)
	local vehicle = vehicleFromArgs(args)
	if not vehicle then
		notify(player, "IGUI_DelCarClaim_NotFound")
		return
	end
	if not near(player, vehicle) then
		notify(player, "IGUI_DelCarClaim_TooFar")
		return
	end
	if M.isWreck(vehicle) then
		notify(player, "IGUI_DelCarClaim_Wreck")
		return
	end
	local s = state()
	local username = player:getUsername()
	local existing = M.entryOf(s, vehicle)
	if existing then
		notify(player, "IGUI_DelCarClaim_AlreadyClaimed")
		return
	end

	local hallId = nil
	if args.hall ~= nil then
		hallId = tostring(args.hall)
		local hall = DelEcon.getHall(DelEcon.getState(), hallId)
		if not DelEcon.canManage(hall, player) then return end
		local limit = M.orgMaxCars()
		if M.countHall(s, hallId) >= limit then
			notify(player, "IGUI_DelCarClaim_OrgLimit", limit)
			return
		end
	else
		local limit = M.maxCars()
		if M.countOwner(s, username) >= limit then
			notify(player, "IGUI_DelCarClaim_Limit", limit)
			return
		end
	end

	local uid = M.vehicleUid(vehicle)
	if not uid then
		uid = newUid(s)
		if not uid then return end
		vehicle:getModData()[M.ID_KEY] = uid
		vehicle:transmitModData()
	end
	local entry = { by = username, allowed = {} }
	if hallId then entry.hall = hallId else entry.owner = username end
	remember(entry, vehicle)
	s.cars[uid] = entry
	seen()[username] = now()
	log(string.format("Claim: %s by %s", describe(uid, entry), username))
	transmit()
	if hallId then
		notify(player, "IGUI_DelCarClaim_ClaimedOrg")
	else
		notify(player, "IGUI_DelCarClaim_Claimed")
	end
end

function Commands.release(player, args)
	local entry, uid = entryFromArgs(args)
	if not entry then
		notify(player, "IGUI_DelCarClaim_NotClaimed")
		return
	end
	if not M.canManage(entry, player) then return end
	log(string.format("Release: %s by %s", describe(uid, entry), player:getUsername()))
	state().cars[uid] = nil
	transmit()
	notify(player, "IGUI_DelCarClaim_Released")
end

function Commands.allow(player, args)
	local entry, uid = entryFromArgs(args)
	if not entry or not M.canEditAccess(entry, player) then return end
	local name = M.trim(args.name)
	if name == "" then return end
	if M.isAllowed(entry, name) then
		notify(player, "IGUI_DelCarClaim_AlreadyAllowed", name)
		return
	end
	if M.allowedCount(entry) >= M.MAX_ALLOWED then
		notify(player, "IGUI_DelCarClaim_AllowedFull", M.MAX_ALLOWED)
		return
	end
	entry.allowed = entry.allowed or {}
	entry.allowed[name] = true
	log(string.format("Allow: %s gets %s from %s", name, describe(uid, entry), player:getUsername()))
	transmit()
	notify(player, "IGUI_DelCarClaim_Allowed", name)
end

function Commands.deny(player, args)
	local entry, uid = entryFromArgs(args)
	if not entry or not M.canEditAccess(entry, player) then return end
	local name = M.trim(args.name)
	if not M.isAllowed(entry, name) then return end
	entry.allowed[name] = nil
	log(string.format("Deny: %s loses %s, by %s", name, describe(uid, entry), player:getUsername()))
	transmit()
	notify(player, "IGUI_DelCarClaim_Denied", name)
end

-- Admin list: days since each owner (or the most recent member of an
-- organization) was online, computed here - the client's clock is not ours.
function Commands.getSeen(player, args)
	if not M.isAdmin(player) then return end
	local s = state()
	local econ = DelEcon.getState()
	local sn = seen()
	local t = now()
	local rows = {}
	for uid, entry in pairs(s.cars) do
		local last
		if entry.hall then
			local hall = econ and type(econ.halls) == "table" and econ.halls[entry.hall]
			last = hall and hallLastSeen(sn, hall, t)
		else
			last = lastSeen(sn, entry.owner, t)
		end
		if last then rows[uid] = math.floor((t - last) / DAY * 10) / 10 end
	end
	sendServerCommand(player, MODULE, "seen", { rows = rows })
end

-- ---------------------------------------------------------------------------
-- Smashed windows of claimed cars, by people who may not use them: for
-- settling disputes (the client sends vehicle/smashWindow).
-- ---------------------------------------------------------------------------

local function onVehicleCommand(command, player, args)
	if command ~= "smashWindow" and command ~= "damageWindow" then return end
	local vehicle = args and getVehicleById(tonumber(args.vehicle) or -1)
	if not vehicle then return end
	local entry, uid = M.entryOf(state(), vehicle)
	if not entry or M.canUse(entry, player) then return end
	log(string.format("Window: %s smashed %s on %s", player:getUsername(), tostring(args.part), describe(uid, entry)))
end

local function onClientCommand(module, command, player, args)
	if module == "vehicle" then
		onVehicleCommand(command, player, args)
		return
	end
	if module ~= MODULE then return end
	local handler = Commands[command]
	if handler then handler(player, args or {}) end
end
Events.OnClientCommand.Add(onClientCommand)
