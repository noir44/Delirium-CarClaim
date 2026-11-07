-- Delirium CarClaim - client plumbing: the read-only copy of the claims,
-- server replies, prompts, and the claim options in the vehicle menu.

if isServer() then return end

require "DCC_Shared"
require "DE_Client"

local M = DelCarClaim
local MODULE = M.MODULE

function M.send(command, args)
	local player = getPlayer()
	if not player then return end
	sendClientCommand(player, MODULE, command, args or {})
end

-- Windows register here to be refreshed when a new state arrives.
M.windows = M.windows or {}

local function refreshWindows()
	for _, window in pairs(M.windows) do
		if window.refresh then window:refresh() end
	end
end

-- ---------------------------------------------------------------------------
-- Initial sync. A single request at connect can be lost (the local player may
-- not exist yet), so ask on game start and player creation and keep asking
-- every game minute until the answer is in - see E:\mods\CLAUDE.md.
-- ---------------------------------------------------------------------------

local stateReceived = false

local function requestSync()
	if not isClient() or stateReceived then return end
	ModData.request(M.STATE_KEY)
end

local function retrySync()
	if stateReceived then
		Events.EveryOneMinute.Remove(retrySync)
		return
	end
	requestSync()
end

Events.OnGameStart.Add(requestSync)
Events.OnCreatePlayer.Add(function() requestSync() end)
Events.EveryOneMinute.Add(retrySync)

local function onReceiveGlobalModData(key, data)
	if key ~= M.STATE_KEY or type(data) ~= "table" then return end
	ModData.remove(key)
	ModData.add(key, data)
	stateReceived = true
	refreshWindows()
end
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)

-- ---------------------------------------------------------------------------
-- Server replies
-- ---------------------------------------------------------------------------

local Replies = {}

function Replies.notify(args)
	local player = getPlayer()
	if not player or type(args.key) ~= "string" then return end
	local text
	if args.arg2 ~= nil then
		text = getText(args.key, tostring(args.arg1), tostring(args.arg2))
	elseif args.arg1 ~= nil then
		text = getText(args.key, tostring(args.arg1))
	else
		text = getText(args.key)
	end
	player:setHaloNote(text, 255, 255, 255, 300)
end

function Replies.seen(args)
	if DelCarClaimListUI then DelCarClaimListUI.receiveSeen(args.rows) end
end

local function onServerCommand(module, command, args)
	if module ~= MODULE then return end
	local handler = Replies[command]
	if handler then handler(args or {}) end
end
Events.OnServerCommand.Add(onServerCommand)

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

-- "Owner: X" / "Organization: Y".
function M.whoText(entry)
	if entry.hall then
		local hall = M.hallOf(entry)
		if hall then return getText("IGUI_DelCarClaim_OwnerOrg", DelEcon.hallName(hall)) end
		return getText("IGUI_DelCarClaim_OwnerOrg", "?")
	end
	return getText("IGUI_DelCarClaim_Owner", tostring(entry.owner))
end

-- Short name of the owner for list columns.
function M.whoShort(entry)
	if entry.hall then
		local hall = M.hallOf(entry)
		return hall and DelEcon.hallName(hall) or "?"
	end
	return tostring(entry.owner)
end

function M.carName(entry)
	local name = entry and entry.name
	if not name or name == "" or name == "?" then return getText("IGUI_DelCarClaim_UnknownCar") end
	local key = "IGUI_VehicleName" .. name
	local text = getText(key)
	if text ~= key then return text end
	return name
end

-- Halo note, not Say(): only this player needs to read it. Throttled, the
-- locks fire on every click.
local lastLockNote = 0
function M.lockedNote(player, entry)
	local t = getTimestampMs()
	if t - lastLockNote < 1500 then return end
	lastLockNote = t
	player:setHaloNote(getText("IGUI_DelCarClaim_Locked", M.whoShort(entry)), 255, 120, 120, 300)
end

-- ---------------------------------------------------------------------------
-- Prompts. ISTextBox / ISModalDialog call onclick(target, button, param1...)
-- and do not pass the player through (see E:\mods\CLAUDE.md): the uid goes
-- as param1.
-- ---------------------------------------------------------------------------

local function onAllowPrompt(target, button, uid)
	if button.internal ~= "OK" then return end
	local name = M.trim(button.parent.entry:getText())
	if name ~= "" then M.send("allow", { uid = uid, name = name }) end
end

function M.promptAllow(player, uid)
	local modal = ISTextBox:new(0, 0, 300, 150, getText("IGUI_DelCarClaim_AllowPrompt"), "", nil, onAllowPrompt,
		player:getPlayerNum(), uid)
	modal:initialise()
	modal:addToUIManager()
end

local function onReleaseConfirm(target, button, uid)
	if button.internal == "YES" then M.send("release", { uid = uid }) end
end

function M.confirmRelease(player, uid, entry)
	local text = getText("IGUI_DelCarClaim_ReleaseConfirm", M.carName(entry))
	local modal = ISModalDialog:new(0, 0, 350, 150, text, true, nil, onReleaseConfirm, player:getPlayerNum(), uid)
	modal:initialise()
	modal:addToUIManager()
end

function M.deny(player, uid, name)
	M.send("deny", { uid = uid, name = name })
end

-- Access list as a submenu: one option per name, click removes.
function M.fillDenyMenu(menu, player, uid, entry)
	local names = M.allowedList(entry)
	if #names == 0 then
		local option = menu:addOption(getText("IGUI_DelCarClaim_NobodyAllowed"))
		option.notAvailable = true
		return
	end
	for _, name in ipairs(names) do
		menu:addOption(name, player, M.deny, uid, name)
	end
end

-- ---------------------------------------------------------------------------
-- Vehicle context menu
-- ---------------------------------------------------------------------------

local function onClaim(player, vehicle, hallId)
	M.send("claim", { vehicle = vehicle:getId(), hall = hallId })
end

local function onOpenList(player, mode, hallId)
	DelCarClaimListUI.open(player, mode, hallId)
end

local function addSubMenu(context, title)
	local option = context:addOption(title)
	local menu = ISContextMenu:getNew(context)
	context:addSubMenu(option, menu)
	return menu
end

local function addFreeOptions(player, context, vehicle)
	if M.isWreck(vehicle) then return end
	local state = M.getState()
	local count, limit = M.countOwner(state, player:getUsername()), M.maxCars()
	local option = context:addOption(getText("IGUI_DelCarClaim_Claim", count, limit), player, onClaim, vehicle, nil)
	if count >= limit then option.notAvailable = true end

	local halls = M.claimableHalls(player)
	if #halls == 0 then return end
	local econ = DelEcon.getState()
	local menu = addSubMenu(context, getText("IGUI_DelCarClaim_ClaimOrg"))
	local orgLimit = M.orgMaxCars()
	for _, id in ipairs(halls) do
		local n = M.countHall(state, id)
		local item = menu:addOption(getText("IGUI_DelCarClaim_ClaimOrgItem", DelEcon.hallName(econ.halls[id]), n, orgLimit),
			player, onClaim, vehicle, id)
		if n >= orgLimit then item.notAvailable = true end
	end
end

local function addClaimedOptions(player, context, uid, entry)
	local menu = addSubMenu(context, M.whoText(entry))
	if M.canManage(entry, player) then
		menu:addOption(getText("IGUI_DelCarClaim_Release"), player, M.confirmRelease, uid, entry)
		menu:addOption(getText("IGUI_DelCarClaim_Allow"), player, M.promptAllow, uid)
		M.fillDenyMenu(addSubMenu(menu, getText("IGUI_DelCarClaim_Deny")), player, uid, entry)
	else
		local names = M.allowedList(entry)
		local option = menu:addOption(getText("IGUI_DelCarClaim_AccessCount", #names))
		option.notAvailable = true
	end
	if entry.hall then
		menu:addOption(getText("IGUI_DelCarClaim_OrgCars"), player, onOpenList, "hall", entry.hall)
	elseif entry.owner == player:getUsername() then
		menu:addOption(getText("IGUI_DelCarClaim_MyCars"), player, onOpenList, "mine", nil)
	end
end

-- Locked car: only who owns it; none of the vanilla options (siphon, tow,
-- mechanics...) are added. Otherwise vanilla first, then the claim options.
local originalFillOutside = ISVehicleMenu.FillMenuOutsideVehicle
function ISVehicleMenu.FillMenuOutsideVehicle(playerNum, context, vehicle, test)
	if test then return originalFillOutside(playerNum, context, vehicle, test) end
	local player = getSpecificPlayer(playerNum)
	local entry, uid = M.entryOf(M.getState(), vehicle)
	if entry and not M.canUse(entry, player) then
		local option = context:addOption(M.whoText(entry))
		option.notAvailable = true
		return
	end
	local result = originalFillOutside(playerNum, context, vehicle, test)
	if entry then
		addClaimedOptions(player, context, uid, entry)
	else
		addFreeOptions(player, context, vehicle)
	end
	return result
end

-- "My cars" anywhere in the world for whoever has some; the full list for
-- admins.
local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
	if test then return end
	local player = getSpecificPlayer(playerNum)
	if not player then return end
	local state = M.getState()
	if M.countOwner(state, player:getUsername()) > 0 then
		context:addOption(getText("IGUI_DelCarClaim_MyCars"), player, onOpenList, "mine", nil)
	end
	if M.isAdmin(player) then
		context:addOption(getText("IGUI_DelCarClaim_AllCars"), player, onOpenList, "all", nil)
	end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- The organization window of Delirium Economy: a "Cars" button for the head,
-- staff and admins. Older Economy builds have no such hook.
if DelEcon.addHallButton then DelEcon.addHallButton({
	title = "IGUI_DelCarClaim_OrgCarsButton",
	visible = function(hall, player) return DelEcon.isOfficial(hall, player) end,
	onclick = function(player, hallId) DelCarClaimListUI.open(player, "hall", hallId) end,
}) end
