-- Delirium CarClaim - definitions shared by client and server.
--
-- A player claims a car for themselves, or the head of an organization
-- (Delirium Economy) claims it for the organization. A claimed car can be
-- used only by its owner, the people on its access list, admins and - for an
-- organization's car - the head and staff of that organization.
--
-- Who owns what lives in one global ModData table written only by the server
-- (server/DCC_Server.lua) and sent to every client as a read-only copy. The
-- car itself carries nothing but its id (modData DCC_ID, or WG_ID for a car
-- claimed under VehicleClaimWG), so a claim can end the moment its timer
-- runs out, whether the car is loaded or not.
--
-- The timer is the one vanilla safehouses use: a personal claim lapses when
-- its owner has not logged in for InactivityDays, an organization's claim
-- when neither its head nor any of its staff has. Driving the car does not
-- matter.
--
-- Nothing in this file changes state.

require "DE_Shared"

DelCarClaim = DelCarClaim or {}
local M = DelCarClaim

M.MODULE = "DelCarClaim"
M.STATE_KEY = "DelCarClaim_State"
M.ID_KEY = "DCC_ID"
M.OLD_ID_KEY = "WG_ID"
-- How close (tiles) a player must stand to claim a car.
M.CLAIM_DISTANCE = 8
-- Longest access list of one car.
M.MAX_ALLOWED = 30

-- state = {
--   cars = { [uid] = { owner = login (personal) | nil, hall = id (organization) | nil,
--                      by = who claimed, allowed = { [login] = true },
--                      name = vehicle script name, x, y, z = last seen position,
--                      wg = true while imported from VehicleClaimWG and not yet seen } },
--   imported = true once the VehicleClaimWG list has been read,
-- }
function M.getState()
	return ModData.get(M.STATE_KEY)
end

function M.cars(state)
	if not state or type(state.cars) ~= "table" then return {} end
	return state.cars
end

function M.vehicleUid(vehicle)
	if not vehicle then return nil end
	local data = vehicle:getModData()
	local id = data[M.ID_KEY]
	if type(id) ~= "string" or id == "" then id = data[M.OLD_ID_KEY] end
	if type(id) ~= "string" or id == "" then return nil end
	return id
end

-- The claim of a car: entry, uid (nil if the car is free).
function M.entryOf(state, vehicle)
	local uid = M.vehicleUid(vehicle)
	if not uid then return nil, nil end
	local entry = M.cars(state)[uid]
	if not entry then return nil, uid end
	return entry, uid
end

-- VehicleClaimWG kept the owner on the car itself.
function M.oldOwnerOnCar(vehicle)
	local data = vehicle:getModData()
	local owner = data.WG_Claim_Owner or data.owner
	if type(owner) ~= "string" or owner == "" then return nil end
	return owner
end

-- What the locks and menus go by. A claim imported from VehicleClaimWG that
-- the server has not compared with its car yet (wg) can name a stale owner -
-- its saved list was only a copy. Until the server does (adoptOld), the car
-- decides here the same way: no owner on it - free, otherwise its owner and
-- the access lists of both. Read-only view, never written back.
function M.liveEntry(state, vehicle)
	local entry, uid = M.entryOf(state, vehicle)
	if not entry or not entry.wg then return entry, uid end
	local owner = M.oldOwnerOnCar(vehicle)
	if not owner then return nil, uid end
	local allowed = {}
	if type(entry.allowed) == "table" then
		for name, on in pairs(entry.allowed) do allowed[name] = on end
	end
	local carAllowed = vehicle:getModData().allowed
	if type(carAllowed) == "table" then
		for _, name in pairs(carAllowed) do
			if type(name) == "string" and name ~= "" then allowed[name] = true end
		end
	end
	return { owner = owner, by = entry.by, allowed = allowed, name = entry.name,
		x = entry.x, y = entry.y, z = entry.z, wg = true }, uid
end

-- ---------------------------------------------------------------------------
-- Sandbox options, read at the point of use (see E:\mods\CLAUDE.md).
-- ---------------------------------------------------------------------------

local function sandbox(name, default)
	local vars = SandboxVars and SandboxVars.DelCarClaim
	local value = vars and tonumber(vars[name])
	if value == nil then return default end
	return value
end

function M.maxCars()
	return sandbox("MaxCars", 3)
end

function M.orgMaxCars()
	return sandbox("OrgMaxCars", 3)
end

function M.inactivityDays()
	return sandbox("InactivityDays", 14)
end

-- ---------------------------------------------------------------------------
-- Rights
-- ---------------------------------------------------------------------------

function M.isAdmin(player)
	return DelShops.hasAdminRights(player)
end

function M.hallOf(entry)
	if not entry or type(entry.hall) ~= "string" then return nil end
	return DelEcon.getHall(DelEcon.getState(), entry.hall)
end

function M.isAllowed(entry, username)
	return entry ~= nil and type(entry.allowed) == "table" and username ~= nil and entry.allowed[username] == true
end

-- May get in, open, drain or repair the car. A free car: anyone.
function M.canUse(entry, player)
	if not entry then return true end
	if not player then return false end
	if M.isAdmin(player) then return true end
	local username = player:getUsername()
	if entry.owner ~= nil and entry.owner == username then return true end
	if M.isAllowed(entry, username) then return true end
	if entry.hall then
		local hall = M.hallOf(entry)
		if hall and DelEcon.isOfficial(hall, player) then return true end
	end
	return false
end

-- May release the claim and edit the access list: the owner; for an
-- organization's car its head; admins always.
function M.canManage(entry, player)
	if not entry or not player then return false end
	if M.isAdmin(player) then return true end
	if entry.hall then return DelEcon.canManage(M.hallOf(entry), player) end
	return entry.owner ~= nil and entry.owner == player:getUsername()
end

-- May give and remove access: whoever manages the car, and for an
-- organization's car also its staff (to give a lift, to hand it in for repair).
function M.canEditAccess(entry, player)
	if M.canManage(entry, player) then return true end
	if not entry or not entry.hall or not player then return false end
	return DelEcon.isStaffOf(M.hallOf(entry), player)
end

-- Organizations this player may claim cars for: ids in creation order.
function M.claimableHalls(player)
	local out = {}
	local econ = DelEcon.getState()
	for _, id in ipairs(DelEcon.hallIds(econ)) do
		if DelEcon.canManage(econ.halls[id], player) then table.insert(out, id) end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Counting and listing
-- ---------------------------------------------------------------------------

-- Personal claims of a player (organization cars do not count).
function M.countOwner(state, username)
	local n = 0
	for _, entry in pairs(M.cars(state)) do
		if not entry.hall and entry.owner == username then n = n + 1 end
	end
	return n
end

function M.countHall(state, hallId)
	local n = 0
	for _, entry in pairs(M.cars(state)) do
		if entry.hall == hallId then n = n + 1 end
	end
	return n
end

-- Access list sorted by login.
function M.allowedList(entry)
	local out = {}
	if not entry or type(entry.allowed) ~= "table" then return out end
	for name, on in pairs(entry.allowed) do
		if on == true then table.insert(out, name) end
	end
	table.sort(out, function(a, b) return string.lower(a) < string.lower(b) end)
	return out
end

function M.allowedCount(entry)
	local n = 0
	if entry and type(entry.allowed) == "table" then
		for _, on in pairs(entry.allowed) do
			if on == true then n = n + 1 end
		end
	end
	return n
end

-- Rows { uid, entry } matching filter(entry), sorted by owner then name.
-- filter = nil lists everything.
function M.list(state, filter)
	local out = {}
	for uid, entry in pairs(M.cars(state)) do
		if not filter or filter(entry) then table.insert(out, { uid = uid, entry = entry }) end
	end
	table.sort(out, function(a, b)
		local ka = (a.entry.hall and ("#" .. a.entry.hall) or (a.entry.owner or "")) .. "|" .. (a.entry.name or "")
		local kb = (b.entry.hall and ("#" .. b.entry.hall) or (b.entry.owner or "")) .. "|" .. (b.entry.name or "")
		if ka == kb then return a.uid < b.uid end
		return string.lower(ka) < string.lower(kb)
	end)
	return out
end

-- Burnt-out and smashed wrecks cannot be claimed and lose their claim.
function M.isWreck(vehicle)
	local script = vehicle and vehicle:getScript()
	local name = script and script:getName() or ""
	return string.find(name, "Burnt", 1, true) ~= nil or string.find(name, "Smashed", 1, true) ~= nil
end

function M.trim(value)
	return (string.gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1"))
end
