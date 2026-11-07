-- Delirium CarClaim - list of claimed cars.
--
-- Three views: "mine" (personal cars of this player), "hall" (cars of one
-- organization: its head, staff and admins see it, the head and admins
-- manage) and "all" (admins: every claim, with how long the owner has been
-- offline). The access list and the claim itself can be changed from here
-- without walking to the car. Rights shown are a convenience: the server
-- checks every command.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "DCC_Client"

local M = DelCarClaim

DelCarClaimListUI = ISCollapsableWindow:derive("DelCarClaimListUI")
DelCarClaimListUI.instance = nil

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local PAD = 10
local ROW_HGT = FONT_HGT_SMALL + 8
local BUTTON_HGT = FONT_HGT_SMALL + 6
local WIDTH = 640
local HEIGHT = 420

local COL = { car = 0, owner = 190, where = 350, access = 450, offline = 530 }

function DelCarClaimListUI.open(player, mode, hallId)
	if DelCarClaimListUI.instance then DelCarClaimListUI.instance:close() end
	local x = (getCore():getScreenWidth() - WIDTH) / 2
	local y = (getCore():getScreenHeight() - HEIGHT) / 2
	local ui = DelCarClaimListUI:new(x, y, WIDTH, HEIGHT, player, mode, hallId)
	ui:initialise()
	ui:instantiate()
	ui.pinButton:setVisible(false)
	ui.collapseButton:setVisible(false)
	ui:addToUIManager()
	DelCarClaimListUI.instance = ui
	M.windows.list = ui
	if mode == "all" then M.send("getSeen", {}) end
	return ui
end

-- Admin view: days offline per claim, from the server.
function DelCarClaimListUI.receiveSeen(rows)
	local ui = DelCarClaimListUI.instance
	if ui and type(rows) == "table" then ui.seenDays = rows end
end

local function drawRow(list, y, item, alt)
	local row = item.item
	local entry = row.entry
	local ui = list.carUI
	local h = list.itemheight
	if list.selected == item.index then
		list:drawRect(0, y, list:getWidth(), h - 1, 0.3, 0.7, 0.35, 0.15)
	end
	list:drawRectBorder(0, y, list:getWidth(), h - 1, 0.3, 0.4, 0.4, 0.4)
	local ty = y + (h - FONT_HGT_SMALL) / 2
	list:drawText(DelShops.trimString(M.carName(entry), 26), COL.car + 4, ty, 1, 1, 1, 1, UIFont.Small)
	list:drawText(DelShops.trimString(M.whoShort(entry), 22), COL.owner + 4, ty, 1, 1, 1, 1, UIFont.Small)
	local where = "?"
	if entry.x and entry.y then where = tostring(entry.x) .. ", " .. tostring(entry.y) end
	list:drawText(where, COL.where + 4, ty, 1, 1, 1, 1, UIFont.Small)
	list:drawText(tostring(M.allowedCount(entry)), COL.access + 4, ty, 1, 1, 1, 1, UIFont.Small)
	if ui and ui.mode == "all" then
		local days = ui.seenDays and ui.seenDays[row.uid]
		list:drawText(days and tostring(days) or "-", COL.offline + 4, ty, 0.8, 0.8, 0.8, 1, UIFont.Small)
	end
	return y + h
end

local function onListMouseDown(list, x, y)
	ISScrollingListBox.onMouseDown(list, x, y)
	local ui = list.carUI
	local entry = list.items[list.selected]
	if ui and entry then ui.selectedUid = entry.item.uid end
end

function DelCarClaimListUI:addButton(title, onclick)
	local width = getTextManager():MeasureStringX(UIFont.Small, title) + 20
	local button = ISButton:new(0, 0, width, BUTTON_HGT, title, self, onclick)
	button:initialise()
	button:instantiate()
	button.borderColor = { r = 0.7, g = 0.7, b = 0.7, a = 0.5 }
	self:addChild(button)
	return button
end

function DelCarClaimListUI:createChildren()
	ISCollapsableWindow.createChildren(self)
	local top = self:titleBarHeight() + PAD + ROW_HGT
	local bottom = self.height - PAD - ROW_HGT * 2 - BUTTON_HGT - PAD
	self.list = ISScrollingListBox:new(PAD, top, self.width - PAD * 2, bottom - top)
	self.list:initialise()
	self.list:instantiate()
	self.list.itemheight = ROW_HGT
	self.list.font = UIFont.Small
	self.list.drawBorder = true
	self.list.doDrawItem = drawRow
	self.list.onMouseDown = onListMouseDown
	self.list.carUI = self
	self:addChild(self.list)

	local y = self.list:getBottom() + PAD
	self.releaseBtn = self:addButton(getText("IGUI_DelCarClaim_Release"), DelCarClaimListUI.onRelease)
	self.allowBtn = self:addButton(getText("IGUI_DelCarClaim_Allow"), DelCarClaimListUI.onAllow)
	self.denyBtn = self:addButton(getText("IGUI_DelCarClaim_Deny"), DelCarClaimListUI.onDeny)
	local x = PAD
	for _, button in ipairs({ self.releaseBtn, self.allowBtn, self.denyBtn }) do
		button:setX(x)
		button:setY(y)
		x = x + button.width + PAD
	end
	self:refresh()
end

function DelCarClaimListUI:filter()
	local player = self.player
	if self.mode == "mine" then
		local username = player:getUsername()
		return function(entry) return not entry.hall and entry.owner == username end
	elseif self.mode == "hall" then
		local hallId = self.hallId
		return function(entry) return entry.hall == hallId end
	end
	return nil
end

function DelCarClaimListUI:refresh()
	local player = self.player
	local state = M.getState()
	if self.mode == "all" and not M.isAdmin(player) then
		self:close()
		return
	end
	if self.mode == "hall" then
		local hall = DelEcon.getHall(DelEcon.getState(), self.hallId)
		if not hall or not DelEcon.isOfficial(hall, player) then
			self:close()
			return
		end
		self.title = DelEcon.hallName(hall) .. ": " .. getText("IGUI_DelCarClaim_OrgCarsButton")
	elseif self.mode == "mine" then
		self.title = getText("IGUI_DelCarClaim_MyCars")
	else
		self.title = getText("IGUI_DelCarClaim_AllCars")
	end

	self.list:clear()
	self.list.selected = 0
	local rows = M.list(state, self:filter())
	for _, row in ipairs(rows) do
		self.list:addItem(row.uid, row)
		if row.uid == self.selectedUid then self.list.selected = #self.list.items end
	end
	self.count = #rows
end

function DelCarClaimListUI:selectedRow()
	local item = self.list.items[self.list.selected]
	if not item then return nil end
	-- The row may be gone from the state since the list was built.
	local entry = M.cars(M.getState())[item.item.uid]
	if not entry then return nil end
	return item.item.uid, entry
end

function DelCarClaimListUI:footer()
	local days = M.inactivityDays()
	if self.mode == "mine" then
		local summary = getText("IGUI_DelCarClaim_MineSummary", self.count or 0, M.maxCars())
		if days > 0 then return summary, getText("IGUI_DelCarClaim_TimerMine", days) end
		return summary, getText("IGUI_DelCarClaim_TimerOff")
	elseif self.mode == "hall" then
		local summary = getText("IGUI_DelCarClaim_OrgSummary", self.count or 0, M.orgMaxCars())
		if days > 0 then return summary, getText("IGUI_DelCarClaim_TimerOrg", days) end
		return summary, getText("IGUI_DelCarClaim_TimerOff")
	end
	return getText("IGUI_DelCarClaim_AllSummary", self.count or 0), getText("IGUI_DelCarClaim_OfflineHint")
end

function DelCarClaimListUI:render()
	ISCollapsableWindow.render(self)
	local uid, entry = self:selectedRow()
	local manage = entry ~= nil and M.canManage(entry, self.player)
	self.releaseBtn:setVisible(manage)
	self.allowBtn:setVisible(manage)
	self.denyBtn:setVisible(manage)

	local hy = self:titleBarHeight() + PAD + (ROW_HGT - FONT_HGT_SMALL) / 2
	local x = self.list.x + 4
	self:drawText(getText("IGUI_DelCarClaim_ColCar"), x + COL.car, hy, 0.8, 0.8, 0.8, 1, UIFont.Small)
	self:drawText(getText("IGUI_DelCarClaim_ColOwner"), x + COL.owner, hy, 0.8, 0.8, 0.8, 1, UIFont.Small)
	self:drawText(getText("IGUI_DelCarClaim_ColWhere"), x + COL.where, hy, 0.8, 0.8, 0.8, 1, UIFont.Small)
	self:drawText(getText("IGUI_DelCarClaim_ColAccess"), x + COL.access, hy, 0.8, 0.8, 0.8, 1, UIFont.Small)
	if self.mode == "all" then
		self:drawText(getText("IGUI_DelCarClaim_ColOffline"), x + COL.offline, hy, 0.8, 0.8, 0.8, 1, UIFont.Small)
	end

	local summary, hint = self:footer()
	local fy = self.height - PAD - ROW_HGT * 2 + (ROW_HGT - FONT_HGT_SMALL) / 2
	self:drawText(summary, PAD, fy, 1, 1, 1, 1, UIFont.Small)
	self:drawText(hint, PAD, fy + ROW_HGT, 0.6, 0.6, 0.6, 1, UIFont.Small)
end

function DelCarClaimListUI:onRelease()
	local uid, entry = self:selectedRow()
	if uid then M.confirmRelease(self.player, uid, entry) end
end

function DelCarClaimListUI:onAllow()
	local uid = self:selectedRow()
	if uid then M.promptAllow(self.player, uid) end
end

-- Names to remove, as a menu under the button.
function DelCarClaimListUI:onDeny()
	local uid, entry = self:selectedRow()
	if not uid then return end
	local button = self.denyBtn
	local context = ISContextMenu.get(self.player:getPlayerNum(), button:getAbsoluteX(),
		button:getAbsoluteY() + button:getHeight())
	M.fillDenyMenu(context, self.player, uid, entry)
end

function DelCarClaimListUI:close()
	ISCollapsableWindow.close(self)
	self:removeFromUIManager()
	DelCarClaimListUI.instance = nil
	M.windows.list = nil
end

function DelCarClaimListUI:new(x, y, width, height, player, mode, hallId)
	local o = ISCollapsableWindow:new(x, y, width, height)
	setmetatable(o, self)
	self.__index = self
	o.player = player
	o.mode = mode or "mine"
	o.hallId = hallId
	o.title = getText("IGUI_DelCarClaim_MyCars")
	o.resizable = false
	o.count = 0
	return o
end
