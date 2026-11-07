-- Delirium CarClaim - what a claimed car refuses to someone without access:
-- getting in, the radial menu, the mechanics window, and any timed action on
-- the car, its parts or its containers (doors, trunk, siphon, towing...).
--
-- These are client-side locks, as in VehicleClaimWG which this mod replaces.
-- A car whose claim is not known yet (the state has not arrived) is open.

if isServer() then return end

require "DCC_Client"

local M = DelCarClaim

-- The claim that keeps this player out of this vehicle, or nil.
local function lockOf(vehicle, player)
	if not vehicle or not player then return nil end
	local entry = M.liveEntry(M.getState(), vehicle)
	if entry and not M.canUse(entry, player) then return entry end
	return nil
end

local function blocked(vehicle, player)
	local entry = lockOf(vehicle, player)
	if entry then
		M.lockedNote(player, entry)
		return true
	end
	return false
end

-- Getting in. ---------------------------------------------------------------

local originalEnterStart = ISEnterVehicle.start
function ISEnterVehicle:start()
	local player = self.character
	if player and player:isLocalPlayer() and blocked(self.vehicle, player) then
		player:StopAllActionQueue()
		return
	end
	originalEnterStart(self)
end

-- Inside anyway (another way in, or the claim arrived later): out.
local function onEnterVehicle(player)
	if not player or not player:isLocalPlayer() then return end
	local vehicle = player:getVehicle()
	if not blocked(vehicle, player) then return end
	if vehicle:isEngineRunning() and vehicle:getSeat(player) == 0 then vehicle:shutOff() end
	ISTimedActionQueue.clear(player)
	ISTimedActionQueue.add(ISExitVehicle:new(player))
end
Events.OnEnterVehicle.Add(onEnterVehicle)

-- Radial menu (V) at or in the car. ----------------------------------------

local originalRadial = ISVehicleMenu.showRadialMenu
function ISVehicleMenu.showRadialMenu(playerObj)
	local vehicle = playerObj:getVehicle() or ISVehicleMenu.getVehicleToInteractWith(playerObj)
	if blocked(vehicle, playerObj) then return end
	originalRadial(playerObj)
end

-- Mechanics window. --------------------------------------------------------

local originalOnMechanic = ISVehicleMenu.onMechanic
function ISVehicleMenu.onMechanic(playerObj, vehicle)
	if blocked(vehicle, playerObj) then return end
	originalOnMechanic(playerObj, vehicle)
end

local originalMechanicsVisible = ISVehicleMechanics.setVisible
function ISVehicleMechanics:setVisible(visible, joypadData)
	if visible and self.vehicle then
		local player = getSpecificPlayer(self.playerNum or 0)
		if blocked(self.vehicle, player) then
			originalMechanicsVisible(self, false, joypadData)
			return
		end
	end
	originalMechanicsVisible(self, visible, joypadData)
end

-- Timed actions. -----------------------------------------------------------

local function vehicleOfContainer(container)
	if not container then return nil end
	local part = container.getVehiclePart and container:getVehiclePart()
	if part then return part:getVehicle() end
	return nil
end

-- Getting in and out and walking to the car are not locked here: getting in
-- is checked in ISEnterVehicle:start, walking is harmless.
local FREE_ACTIONS = {
	ISEnterVehicle = true,
	ISExitVehicle = true,
	ISSwitchVehicleSeat = true,
	ISPathFindAction = true,
	ISWalkToTimedAction = true,
}

-- Every vehicle an action touches: the car (vehicle, part), both ends of a
-- tow (vehicleA/vehicleB), the containers of a transfer, the container of the
-- item worn or equipped.
local function vehiclesOf(action)
	local out = {}
	local function add(vehicle)
		if vehicle then table.insert(out, vehicle) end
	end
	add(action.vehicle)
	add(action.vehicleA)
	add(action.vehicleB)
	if action.part and action.part.getVehicle then add(action.part:getVehicle()) end
	add(vehicleOfContainer(action.srcContainer))
	add(vehicleOfContainer(action.destContainer))
	local item = action.item
	if item and item.getContainer then add(vehicleOfContainer(item:getContainer())) end
	return out
end

local originalQueueAdd = ISTimedActionQueue.add
ISTimedActionQueue.add = function(action, ...)
	local player = action and action.character
	if player and instanceof(player, "IsoPlayer") and player:isLocalPlayer() and not FREE_ACTIONS[action.Type] then
		for _, vehicle in ipairs(vehiclesOf(action)) do
			if blocked(vehicle, player) then return end
		end
	end
	return originalQueueAdd(action, ...)
end
