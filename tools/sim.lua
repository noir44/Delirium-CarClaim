-- Offline check of server/DCC_Server.lua with stubbed PZ APIs.
-- Run from the repository root:  lua5.4 tools/sim.lua
-- Needs Delirium-Economy and Delirium-Shops checked out next to this
-- repository (DE_Shared.lua, DS_Shared.lua).

local ROOT = "Contents/mods/DeliriumCarClaim/42/media/lua/"
local ECON = "../Delirium-Economy/Contents/mods/DeliriumEconomy/42/media/lua/"
local SHOPS = "../Delirium-Shops/Contents/mods/DeliriumShops/42/media/lua/"
package.path = ROOT .. "shared/?.lua;" .. ECON .. "shared/?.lua;" .. SHOPS .. "shared/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local clock = 1800000000
local realTime = os.time
os.time = function() return clock end

local md = {}
ModData = {
	getOrCreate = function(k) md[k] = md[k] or {} return md[k] end,
	get = function(k) return md[k] end,
	transmit = function() end, request = function() end,
}
function isClient() return false end
function isServer() return true end
function writeLog() end
local rnd = 0
function ZombRand(n) rnd = rnd + 1 return rnd % n end
local sent = {}
function sendServerCommand(p, m, c, a) table.insert(sent, { p = p and p:getUsername(), c = c, a = a }) end
local handlers = {}
Events = setmetatable({}, { __index = function(t, k)
	local e = { Add = function(f) handlers[k] = handlers[k] or {} table.insert(handlers[k], f) end, Remove = function() end }
	rawset(t, k, e)
	return e
end })
local function list(t)
	return {
		size = function() return #t end,
		get = function(_, i) return t[i + 1] end,
		toArray = function() return t end,
	}
end
local function player(name, admin, x, y)
	return { getUsername = function() return name end, getAccessLevel = function() return admin and "admin" or "" end,
		getX = function() return x or 0 end, getY = function() return y or 0 end }
end
local online = {}
function getOnlinePlayers() return list(online) end
function getActivatedMods() return list({ "\\DelShops", "\\DelEcon", "\\DelCarClaim" }) end

local vehicles = {}
local loaded = {}
local function car(id, script, x, y, modData)
	local v = { md = modData or {} }
	function v.getId() return id end
	function v.getModData() return v.md end
	function v.transmitModData() end
	function v.getScript() return { getName = function() return script end } end
	function v.getX() return x end
	function v.getY() return y end
	function v.getZ() return 0 end
	vehicles[id] = v
	return v
end
function getVehicleById(id) return vehicles[id] end
function getCell() return { getVehicles = function() return list(loaded) end } end
require "DS_Shared"

-- One organization: head "boss", staff "emp".
md.DelEcon_State = { nextId = 2, houses = {}, halls = { ["1"] = { name = "Garage", mayor = "boss", treasury = 0, price = 0.1,
	staff = { emp = { title = "driver", salary = 0, owed = 0 } } } } }

-- What VehicleClaimWG left in the save: three claims of "old" and one of
-- "old2" that was about to be dropped (pending).
md.VehicleClaimWG_List = { old = { ["WG-1-1"] = { x = 5, y = 5, z = 0, name = "CarA" }, ["WG-2-2"] = { x = 6, y = 6, z = 0, name = "CarB" },
	["WG-3-3"] = { x = 7, y = 7, z = 0, name = "CarC" }, ["WG-5-5"] = { x = 50, y = 50, z = 0, name = "CarE" } }, old2 = { ["WG-4-4"] = { x = 8, y = 8, z = 0, name = "CarD" } } }
md.VehicleClaimWG_PendingUnclaims = { ["WG-4-4"] = true }

dofile(ROOT .. "server/DCC_Server.lua")
for _, f in ipairs(handlers.OnInitGlobalModData) do f() end

local function cmd(p, c, a) for _, f in ipairs(handlers.OnClientCommand) do f("DelCarClaim", c, p, a or {}) end end
local function hour() for _, f in ipairs(handlers.EveryHours) do f() end end
local function minute() for _, f in ipairs(handlers.EveryOneMinute) do f() end end
local function days(n) clock = clock + math.floor(n * 86400) end
local fails = 0
local function check(cond, msg)
	print((cond and "ok   " or "FAIL ") .. msg)
	if not cond then fails = fails + 1 end
end
local function lastNote() return sent[#sent] and sent[#sent].a and sent[#sent].a.key end
local S = md.DelCarClaim_State
local function count(f) local n = 0 for _, e in pairs(S.cars) do if not f or f(e) then n = n + 1 end end return n end

SandboxVars = { DelCarClaim = { MaxCars = 2, OrgMaxCars = 1, InactivityDays = 14 } }

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

check(count() == 4, "import: 4 claims taken over, the pending one skipped")
check(S.cars["WG-1-1"].owner == "old" and S.cars["WG-1-1"].wg, "import: owner kept, marked as not yet seen")
for _, f in ipairs(handlers.OnInitGlobalModData) do f() end
check(count() == 4, "import runs once")

-- Cars seen: WG-1-1 free on the car (dropped), WG-2-2 with another owner and
-- an access list, WG-3-3 burnt.
loaded = {
	car(101, "CarA", 5, 5, { WG_ID = "WG-1-1" }),
	car(102, "CarB", 9, 9, { WG_ID = "WG-2-2", WG_Claim_Owner = "real", allowed = { "pal" } }),
	car(103, "CarC_Burnt", 7, 7, { WG_ID = "WG-3-3", WG_Claim_Owner = "old" }),
}
local view = DelCarClaim.liveEntry(S, loaded[2])
check(view and view.owner == "real" and view.allowed.pal and S.cars["WG-2-2"].owner == "old",
	"live view: owner and access from the car before the server compares, state untouched")
check(DelCarClaim.liveEntry(S, loaded[1]) == nil, "live view: free on the car -> free")
minute()
check(S.cars["WG-1-1"] == nil, "adopt within a game minute: free on the car -> released")
check(S.cars["WG-2-2"] and S.cars["WG-2-2"].owner == "real" and S.cars["WG-2-2"].allowed.pal, "adopt: owner and access list from the car")
check(S.cars["WG-2-2"].wg == nil and S.cars["WG-2-2"].x == 9, "adopt: done once, position updated")
check(S.cars["WG-3-3"] == nil, "wreck released")

-- Not loaded yet, then claimed by someone else: free on the car, so the
-- claim goes through without waiting for a scan.
check(S.cars["WG-5-5"].wg, "unloaded import stays unchecked")
local e5 = car(105, "CarE", 50, 50, { WG_ID = "WG-5-5" })
cmd(player("newbie", false, 50, 50), "claim", { vehicle = 105 })
check(S.cars["WG-5-5"] and S.cars["WG-5-5"].owner == "newbie" and not S.cars["WG-5-5"].wg,
	"claim of an import free on the car: adopted first, then claimed")
S.cars["WG-5-5"] = nil

-- ---------------------------------------------------------------------------
-- Claims and limits
-- ---------------------------------------------------------------------------

local ann = player("ann", false, 0, 0)
local boss = player("boss", false, 0, 0)
local emp = player("emp", false, 0, 0)
local adm = player("adm", true, 0, 0)
local c1, c2, c3, c4 = car(1, "Van", 1, 1), car(2, "Van", 2, 2), car(3, "Van", 3, 3), car(4, "Van", 4, 4)
local far = car(5, "Van", 100, 100)

cmd(ann, "claim", { vehicle = 5 })
check(lastNote() == "IGUI_DelCarClaim_TooFar", "too far")
cmd(ann, "claim", { vehicle = 1 })
cmd(ann, "claim", { vehicle = 2 })
check(count(function(e) return e.owner == "ann" end) == 2, "two personal claims")
local uid1 = c1.md.DCC_ID
check(uid1 and S.cars[uid1].owner == "ann", "car got an id, entry owned by ann")
cmd(ann, "claim", { vehicle = 3 })
check(lastNote() == "IGUI_DelCarClaim_Limit", "personal limit")
cmd(boss, "claim", { vehicle = 1 })
check(lastNote() == "IGUI_DelCarClaim_AlreadyClaimed", "already claimed")

cmd(emp, "claim", { vehicle = 3, hall = "1" })
check(c3.md.DCC_ID == nil, "staff cannot claim for the organization")
cmd(boss, "claim", { vehicle = 3, hall = "1" })
local uid3 = c3.md.DCC_ID
check(uid3 and S.cars[uid3].hall == "1" and S.cars[uid3].owner == nil, "head claims for the organization")
cmd(boss, "claim", { vehicle = 4, hall = "1" })
check(lastNote() == "IGUI_DelCarClaim_OrgLimit", "organization limit")
cmd(boss, "claim", { vehicle = 4 })
check(S.cars[c4.md.DCC_ID].owner == "boss", "organization car does not count against the head's own limit")

-- ---------------------------------------------------------------------------
-- Rights
-- ---------------------------------------------------------------------------

local M = DelCarClaim
local stranger = player("zed", false)
check(M.canUse(S.cars[uid3], emp) and M.canUse(S.cars[uid3], boss), "staff and head use the organization car")
check(not M.canUse(S.cars[uid3], stranger), "stranger cannot")
check(not M.canManage(S.cars[uid3], emp) and M.canManage(S.cars[uid3], boss), "only the head manages it")
cmd(emp, "allow", { uid = uid3, name = "zed" })
check(M.canUse(S.cars[uid3], stranger), "staff give access to an outsider")
cmd(emp, "deny", { uid = uid3, name = "zed" })
check(not M.canUse(S.cars[uid3], stranger), "staff remove access")
cmd(emp, "release", { uid = uid3 })
check(S.cars[uid3] ~= nil, "staff cannot release")
cmd(stranger, "allow", { uid = uid3, name = "zed" })
check(not M.canUse(S.cars[uid3], stranger), "outsider cannot give access")
cmd(boss, "allow", { uid = uid3, name = " zed " })
check(M.canUse(S.cars[uid3], stranger), "head gives access to an outsider")
check(not M.canEditAccess(S.cars[uid1], emp), "staff edit nothing on personal cars")
cmd(ann, "allow", { uid = uid1, name = "zed" })
check(M.canUse(S.cars[uid1], stranger), "owner gives access")
cmd(ann, "deny", { uid = uid1, name = "zed" })
check(not M.canUse(S.cars[uid1], stranger), "owner removes access")
check(M.canUse(S.cars[uid1], adm) and M.canManage(S.cars[uid1], adm), "admin uses and manages any car")

-- ---------------------------------------------------------------------------
-- Login timer
-- ---------------------------------------------------------------------------

-- ann stays away, boss logs in now and then, emp never; "real" is never seen
-- (counting started at the first hour above).
online = { boss }
for _ = 1, 3 do
	days(5)
	minute()
	hour()
end
check(S.cars[uid1] == nil and S.cars[c2.md.DCC_ID] == nil, "ann offline 15 days: her claims released")
check(S.cars[c4.md.DCC_ID] ~= nil, "boss logs in: his car stays without being driven")
check(S.cars[uid3] ~= nil, "organization car stays while the head logs in")
check(S.cars["WG-2-2"] ~= nil, "owner taken from the car: counting starts when the mod first hears of them")

online = { emp }
days(10) minute() hour()
days(5) minute() hour()
check(S.cars[uid3] ~= nil, "organization car stays while only staff log in")
check(S.cars[c4.md.DCC_ID] == nil, "boss away 15 days: his personal car released")
check(S.cars["WG-2-2"] == nil, "imported claim of a player never seen released after the timer")

online = {}
days(15) hour()
check(S.cars[uid3] == nil, "nobody of the organization for 15 days: released")

-- ---------------------------------------------------------------------------
-- Release and organization deletion
-- ---------------------------------------------------------------------------

online = { ann, boss }
minute()
cmd(ann, "claim", { vehicle = 1 })
cmd(stranger, "release", { uid = uid1 })
check(S.cars[uid1] ~= nil, "stranger cannot release")
cmd(ann, "release", { uid = uid1 })
check(S.cars[uid1] == nil, "owner releases")
check(c1.md.DCC_ID == uid1, "the car keeps its id for a later claim")

cmd(boss, "claim", { vehicle = 3, hall = "1" })
check(S.cars[uid3] and S.cars[uid3].hall == "1", "organization claims again")
md.DelEcon_State.halls["1"] = nil
for _, hook in ipairs(DelEcon.hallDeletedHooks) do hook("1") end
check(S.cars[uid3] == nil, "organization deleted: its cars released")

SandboxVars.DelCarClaim.InactivityDays = 0
cmd(ann, "claim", { vehicle = 1 })
online = {}
days(400) hour()
check(S.cars[uid1] ~= nil, "InactivityDays = 0: claims never end")

os.time = realTime
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
