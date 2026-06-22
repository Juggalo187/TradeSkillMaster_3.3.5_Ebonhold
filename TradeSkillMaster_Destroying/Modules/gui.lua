-- ------------------------------------------------------------------------------ --
--                           TradeSkillMaster_Destroying                          --
--           http://www.curse.com/addons/wow/tradeskillmaster_destroying          --
--                                                                                --
--             A TradeSkillMaster Addon (http://tradeskillmaster.com)             --
--    All Rights Reserved* - Detailed license information included with addon.    --
-- ------------------------------------------------------------------------------ --

-- load the parent file (TSM) into a local variable and register this file as a module
local TSM = select(2, ...)
local GUI = TSM:NewModule("GUI", "AceEvent-3.0")

-- loads the localization table --
local L = LibStub("AceLocale-3.0"):GetLocale("TradeSkillMaster_Destroying") 

local private = {data={}, ignore={}, discountSettingsChanged=false, tooltipCache={}}
TSMAPI:RegisterForTracing(private, "TSM_Destroying.GUI_private")

---
function private:AddAgeToTooltip(cached, gameTooltip)
    if not cached or not cached.itemString then return end
    
    local ageInSeconds = TSM:GetDataAge(cached.itemString)
    local ageCategory, ageText = TSM:GetDataAgeCategory(ageInSeconds)
    
    local color, statusText
    if ageCategory == "fresh" then
        color = "|cFF00FF00" -- Green
        statusText = "Fresh"
    elseif ageCategory == "warning" then
        color = "|cFFFFFF00" -- Yellow  
        statusText = "Aged"
    else
        color = "|cFFFF0000" -- Red
        statusText = "Outdated"
    end
    
    gameTooltip:AddLine(" ")
    gameTooltip:AddDoubleLine("Auction Data Age:", color .. statusText .. " (" .. ageText .. ")|r", 1, 1, 1, 1, 1, 1)
    
    if ageCategory == "warning" then
        gameTooltip:AddLine("|cFFFFFF00Consider rescanning for accurate prices|r", 1, 1, 1, true)
    elseif ageCategory == "old" then
        gameTooltip:AddLine("|cFFFF0000Prices may be inaccurate - rescan recommended|r", 1, 1, 1, true)
    end
end

function private:GetSimpleValueComparison(cached)
    -- Used when suggestion system is disabled
    local lines = {}
    
    if cached.hasAuctionValue then
        tinsert(lines, "AH: " .. TSMAPI:FormatTextMoney(cached.totalAuctionValue))
    else
        tinsert(lines, "AH: |cFF888888No Data|r")
    end
    
    if cached.hasVendorValue then
        tinsert(lines, "Vendor: " .. TSMAPI:FormatTextMoney(cached.totalVendorValue))
    else
        tinsert(lines, "Vendor: |cFF888888No Data|r")
    end
    
    if cached.hasDestructionValue then
        tinsert(lines, "Destroy: " .. TSMAPI:FormatTextMoney(cached.totalDestructionValue))
    else
        tinsert(lines, "Destroy: |cFF888888No Data|r")
    end
    
    return table.concat(lines, " | ")
end

-- Get recommendation value for sorting
function private:GetRecommendationValue(cached, data)
    local auctionValue = cached.totalAuctionValue or 0
    local vendorValue = cached.totalVendorValue or 0
    local destructionValue = cached.totalDestructionValue or 0
    local hasAuction = cached.hasAuctionValue
    local hasVendor = cached.hasVendorValue
    local hasDestruction = cached.hasDestructionValue
    local isSoulbound = cached.isSoulbound
    
    -- SOULBOUND ITEMS: Only compare vendor vs destruction
    if isSoulbound then
        if not hasDestruction then return -999999 end
        return destructionValue - vendorValue
    end
    
    -- NO AUCTION DATA: Low priority
    if not hasAuction then
        return -999999
    end
    
    -- For filtering purposes, we want to properly rank each method
    if hasDestruction and destructionValue > math.max(auctionValue, vendorValue) then
        return destructionValue + 1000000  -- Bonus for being best destruction
    elseif hasAuction and auctionValue > math.max(destructionValue, vendorValue) then
        return auctionValue + 500000  -- Bonus for being best auction
    elseif hasVendor and vendorValue > math.max(destructionValue, auctionValue) then
        return vendorValue  -- Vendor gets no bonus
    end
    
    -- FALLBACK: Return the highest available value
    return math.max(auctionValue, vendorValue, destructionValue)
end

-- Apply filters to ST data
function private:ApplyFilters(stData)
    local sortBy = TSM.db.profile.sortBy or "suggestion"
    
    -- If we're in Destroy Only mode, default to quantity sorting for practicality
    if TSM.db.profile.showOnlyDestroy and sortBy == "suggestion" then
        sortBy = "quantity"
    end
	
    if not TSM.db.profile.enableSuggestions and sortBy == "suggestion" then
        -- Fallback to name sorting if suggestions disabled but suggestion sort selected
        sortBy = "name"
        TSM.db.profile.sortBy = "name"
        if private.frame and private.frame.filterButtons and private.frame.filterButtons.sort then
            private.frame.filterButtons.sort:SetText("Sort: Name")
        end
    end
    
    -- Apply Destroy Only filter
	if TSM.db.profile.showOnlyDestroy then
		local filteredData = {}
		for _, data in ipairs(stData) do
			local manualOverride = TSM:GetManualOverride(data.itemString)
			
			-- In Destroy Only mode, show items that are either:
			-- 1. Manually set to destroy OR
			-- 2. Meet the normal destruction criteria (and not manually set to something else)
			if manualOverride == "destroy" then
				-- Always show items manually set to destroy
				tinsert(filteredData, data)
			else
				-- Calculate values directly without relying on cache
				local auctionValueFunc = TSMAPI:ParseCustomPrice("DBMarket")
				local auctionValue = auctionValueFunc and auctionValueFunc(data.itemString) or 0
				local hasAuctionValue = auctionValue > 0
				
				-- Get discounted AH value
				local discountedAH = auctionValue
				if hasAuctionValue then
					if data.spell == GetSpellInfo(TSM.spells.disenchant) then
						discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "disenchant")
					elseif data.spell == GetSpellInfo(TSM.spells.milling) then
						discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "milling") 
					elseif data.spell == GetSpellInfo(TSM.spells.prospect) then
						discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "prospect")
					end
				end
				local totalDiscountedAH = discountedAH * data.quantity
				
				-- Get vendor value
				local vendorSell = 0
				local itemInfo = {TSMAPI:GetSafeItemInfo(data.itemString)}
				if #itemInfo >= 11 then
					vendorSell = itemInfo[11] or 0
				end
				local totalVendorValue = vendorSell * data.quantity
				local hasVendorValue = vendorSell > 0
				
				-- Get destruction value
				local destructionValue = TSM:GetDestroyValue(data.itemString, data.spell) or 0
				local totalDestructionValue = destructionValue * data.numDestroys
				local hasDestructionValue = destructionValue > 0
				
				-- Check if soulbound
				local isSoulbound = private:IsItemSoulbound(data.bag, data.slot)
				
				-- If item has manual override set to auction or vendor, don't show in Destroy Only
				if manualOverride == "auction" or manualOverride == "vendor" then
					-- Skip items manually set to auction or vendor in Destroy Only mode
					-- do nothing - don't add to filteredData
				else
					-- Use normal logic for other items (auto or no override)
					local shouldShow = false
					
					if isSoulbound then
						-- SOULBOUND ITEMS: Show if destruction is better than vendor
						shouldShow = hasDestructionValue and totalDestructionValue > totalVendorValue
					else
						-- Not soulbound: Show if we have destruction value AND it's better than other options
						if TSM.db.profile.enableSuggestions then
							-- With suggestions enabled, use the original logic
							shouldShow = hasDestructionValue and totalDestructionValue > math.max(totalDiscountedAH, totalVendorValue)
						else
							-- With suggestions disabled, be more permissive in Destroy Only mode
							shouldShow = hasDestructionValue
						end
					end
					
					if shouldShow then
						tinsert(filteredData, data)
					end
				end
			end
		end
		stData = filteredData
	end
    
    -- Sort data (existing code remains the same)
    if sortBy == "suggestion" then
        table.sort(stData, function(a, b)
            -- Calculate recommendation values directly instead of relying on cache
            local aValue = private:CalculateRecommendationValue(a)
            local bValue = private:CalculateRecommendationValue(b)
            
            return aValue > bValue -- Higher value = better recommendation
        end)
    elseif sortBy == "name" then
        table.sort(stData, function(a, b)
            -- Extract clean item names from links for proper alphabetical sorting
            local aName = GetItemInfo(a.link) or a.link
            local bName = GetItemInfo(b.link) or b.link
            return aName < bName
        end)
    elseif sortBy == "quantity" then
        table.sort(stData, function(a, b)
            -- Sort by total quantity (descending)
            return a.quantity > b.quantity
        end)
    end
    
    return stData
end

-- Helper function to calculate recommendation value without cache
function private:CalculateRecommendationValue(data)
    if not data then return -999999 end
    
    -- Get values directly instead of from cache
    local auctionValueFunc = TSMAPI:ParseCustomPrice("DBMarket")
    local auctionValue = auctionValueFunc and auctionValueFunc(data.itemString) or 0
    local totalAuctionValue = auctionValue * data.quantity
    
    -- Get discounted AH value
    local discountedAH = auctionValue
    if data.spell == GetSpellInfo(TSM.spells.disenchant) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "disenchant")
    elseif data.spell == GetSpellInfo(TSM.spells.milling) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "milling") 
    elseif data.spell == GetSpellInfo(TSM.spells.prospect) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "prospect")
    end
    local totalDiscountedAH = discountedAH * data.quantity
    
    -- Get vendor value
    local vendorSell = 0
    local itemInfo = {TSMAPI:GetSafeItemInfo(data.itemString)}
    if #itemInfo >= 11 then
        vendorSell = itemInfo[11] or 0
    end
    local totalVendorValue = vendorSell * data.quantity
    
    -- Get destruction value
    local destructionValue = TSM:GetDestroyValue(data.itemString, data.spell) or 0
    local totalDestructionValue = destructionValue * data.numDestroys
    
    -- Check if soulbound
    local isSoulbound = private:IsItemSoulbound(data.bag, data.slot)
    
    -- Calculate recommendation value (same logic as in GetRecommendationValue)
    local auctionValueToUse = totalDiscountedAH
    local vendorValue = totalVendorValue
    local destructionValue = totalDestructionValue
    local hasAuction = auctionValue > 0
    local hasVendor = vendorSell > 0
    local hasDestruction = destructionValue > 0
    
    -- SOULBOUND ITEMS: Only compare vendor vs destruction
    if isSoulbound then
        if not hasDestruction then return -999999 end
        return destructionValue - vendorValue
    end
    
    -- NO AUCTION DATA: Low priority
    if not hasAuction then
        return -999999
    end
    
    -- For filtering purposes, we want to properly rank each method
    if hasDestruction and destructionValue > math.max(auctionValueToUse, vendorValue) then
        return destructionValue + 1000000  -- Bonus for being best destruction
    elseif hasAuction and auctionValueToUse > math.max(destructionValue, vendorValue) then
        return auctionValueToUse + 500000  -- Bonus for being best auction
    elseif hasVendor and vendorValue > math.max(destructionValue, auctionValueToUse) then
        return vendorValue  -- Vendor gets no bonus
    end
    
    -- FALLBACK: Return the highest available value
    return math.max(auctionValueToUse, vendorValue, destructionValue)
end

function GUI:ClearDestroyCache()
    if TSM and TSM.IsDestroyable then
        -- Access the destroyCache from the main TSM module
        TSM.destroyCache = {}
    end
end
---

function GUI:OnEnable()
	private.frame = private:CreateDestroyingFrame()
	TSMAPI:CreateEventBucket("BAG_UPDATE", function() private:UpdateST() end, 0.2)
	GUI:RegisterEvent("LOOT_SLOT_CLEARED", private.LootChanged)
	GUI:RegisterEvent("LOOT_OPENED", private.LootOpened)
	GUI:RegisterEvent("LOOT_CLOSED", private.LootChanged)
	GUI:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	GUI:RegisterEvent("UI_ERROR_MESSAGE", function(_, msg) if msg == ERR_INVALID_ITEM_TARGET or msg == SPELL_FAILED_ERROR then private.LootChanged() end end)
	TSMAPI:CreateTimeDelay("destroyingSTUpdate", 1, function() private:UpdateST() end)
end

function GUI:ClearTooltipCache()
    private.tooltipCache = {}
end

function GUI:ShowFrame()
	private.hidden = nil
	self:ClearTooltipCache()
	private:UpdateST(true)
	
	-- Force show the frame even if no items are found initially
	if private.frame then
		private.frame:Show()
		private:UpdateST(true) -- Force update
	end
end

function private:CreateDestroyingFrame()
    local frameDefaults = {
        x = 850,
        y = 450,
        width = 320,
        height = 380,
        scale = 1,
    }
    local frame = TSMAPI:CreateMovableFrame("TSMDestroyingFrame", frameDefaults)
    frame:SetFrameStrata("HIGH")
    TSMAPI.Design:SetFrameBackdropColor(frame)
    
    -- Make the frame resizable
    frame:SetResizable(true)
    frame:SetMinResize(250, 300) -- Minimum width, height
    
    -- Add resize handle
    local resizeButton = CreateFrame("Button", nil, frame)
    resizeButton:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeButton:SetSize(16, 16)
    resizeButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeButton:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeButton:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            frame:StartSizing("BOTTOMRIGHT")
            self:GetHighlightTexture():Hide()
        end
    end)
    resizeButton:SetScript("OnMouseUp", function(self, button)
        frame:StopMovingOrSizing()
        self:GetHighlightTexture():Show()
        
        -- Save new size to defaults
        local width, height = frame:GetSize()
        frameDefaults.width = width
        frameDefaults.height = height
        
        -- Update scrolling table size
        if frame.st then
            frame.st:SetPoint("TOPLEFT", 5, -55)
            frame.st:SetPoint("BOTTOMRIGHT", -5, 30)
        end
    end)
    
    -- Simple title
    local title = TSMAPI.GUI:CreateLabel(frame)
    title:SetText("TSM Destroying")
    title:SetPoint("TOPLEFT", 8, -8)
    title:SetPoint("TOPRIGHT", -25, -8)
    title:SetHeight(20)
    title:SetJustifyH("LEFT")
    
    -- Simple close button
    local closeBtn = TSMAPI.GUI:CreateButton(frame, 14)
    closeBtn:SetPoint("TOPRIGHT", -3, -3)
    closeBtn:SetWidth(20)
    closeBtn:SetHeight(20)
    closeBtn:SetText("X")
    closeBtn:SetScript("OnClick", function()
        if InCombatLockdown() then return end
        frame:Hide()
    end)
    
    -- Sort button
    local sortBtn = TSMAPI.GUI:CreateButton(frame, 12)
    sortBtn:SetPoint("TOPLEFT", 8, -30)
    sortBtn:SetWidth(120)
    sortBtn:SetHeight(20)
    sortBtn:SetText("Sort: Suggestion")
	sortBtn:SetScript("OnClick", function()
    -- If we're in Destroy Only mode, only allow name and quantity sorting
    if TSM.db.profile.showOnlyDestroy then
        if TSM.db.profile.sortBy == "name" then
            TSM.db.profile.sortBy = "quantity"
            sortBtn:SetText("Sort: Quantity")
        else
            TSM.db.profile.sortBy = "name"
            sortBtn:SetText("Sort: Name")
        end
    else
        -- Normal mode with all three options
        if not TSM.db.profile.enableSuggestions then
            -- When suggestions disabled, only cycle through name and quantity
            if TSM.db.profile.sortBy == "name" then
                TSM.db.profile.sortBy = "quantity"
                sortBtn:SetText("Sort: Quantity")
            else
                TSM.db.profile.sortBy = "name"
                sortBtn:SetText("Sort: Name")
            end
        else
            -- Original behavior with all three options
            if TSM.db.profile.sortBy == "suggestion" then
                TSM.db.profile.sortBy = "name"
                sortBtn:SetText("Sort: Name")
            elseif TSM.db.profile.sortBy == "name" then
                TSM.db.profile.sortBy = "quantity"
                sortBtn:SetText("Sort: Quantity")
            else
                TSM.db.profile.sortBy = "suggestion"
                sortBtn:SetText("Sort: Suggestion")
            end
        end
    end
    private:UpdateST(true) -- Force update with new sorting
end)
	
	-- Destroy Only filter button
	local destroyOnlyBtn = TSMAPI.GUI:CreateButton(frame, 12)
	destroyOnlyBtn:SetPoint("TOPLEFT", sortBtn, "TOPRIGHT", 5, 0)
	destroyOnlyBtn:SetWidth(100)
	destroyOnlyBtn:SetHeight(20)
	-- Initialize button text from saved setting
	if TSM.db.profile.showOnlyDestroy then
		destroyOnlyBtn:SetText("Show: Destroy Only")
	else
		destroyOnlyBtn:SetText("Show: All")
	end
	
	destroyOnlyBtn:SetScript("OnClick", function()
		TSM.db.profile.showOnlyDestroy = not TSM.db.profile.showOnlyDestroy
		
		if TSM.db.profile.showOnlyDestroy then
			destroyOnlyBtn:SetText("Show: Destroy Only")
			-- If current sort is suggestion, switch to name when entering Destroy Only mode
			if TSM.db.profile.sortBy == "suggestion" then
				TSM.db.profile.sortBy = "name"
				if frame.filterButtons and frame.filterButtons.sort then
					frame.filterButtons.sort:SetText("Sort: Name")
				end
			end
		else
			destroyOnlyBtn:SetText("Show: All")
		end
		private:UpdateST(true)
	end)
    
    frame.filterButtons = { sort = sortBtn, destroyOnly = destroyOnlyBtn }
    
    -- Simple line separator
    TSMAPI.GUI:CreateHorizontalLine(frame, -52)
    
    -- Scrolling table
    local stCols = {
        { name = "Item", width = 0.7 },
        { name = "Stack Size", width = 0.3, align = "CENTER" },
    }
    
    local handlers = {
    OnClick = function(_, data, self, button)
    if not data then return end
    
    if button == "LeftButton" and IsShiftKeyDown() then
        -- Shift+Left click: Cycle manual override
        local currentAction = private:GetCurrentRecommendedAction(data)
        local newAction = TSM:CycleManualOverride(data.itemString, currentAction)
        
        local actionTexts = {
            destroy = "Destroy",
            auction = "Sell on AH", 
            vendor = "Vendor",
            auto = "Auto (Default)"
        }
        
        TSM:Printf("Manual override for %s: %s", data.link, actionTexts[newAction] or "Auto")
        private:UpdateST(true)
        
    elseif button == "RightButton" then
        if IsShiftKeyDown() then
            TSM.db.global.ignore[data.itemString] = true
            TSM:Printf(L["Ignoring all %s permanently. You can undo this in the Destroying options."], data.link)
            TSM.Options:UpdateIgnoreST()
        else
            private.ignore[data.itemString] = true
            TSM:Printf(L["Ignoring all %s this session (until your UI is reloaded)."], data.link)
        end
        private:UpdateST()
    end
end,
    OnEnter = function(_, data, self)
        if not data then return end
        if not GameTooltip then
            GameTooltip = _G["GameTooltip"]
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        
        -- Get item information
        local itemString = data.itemString
        local quantity = data.quantity
        local itemName = data.link
        
        -- Create cache key that includes discount settings
        local discountHash = ""
        if TSM.db.profile.discountPercentages then
            for profession, ages in pairs(TSM.db.profile.discountPercentages) do
                for age, value in pairs(ages) do
                    discountHash = discountHash .. profession .. age .. tostring(value)
                end
            end
        end
        
        local cacheKey = itemString .. ":" .. data.spell .. ":" .. quantity .. ":" .. discountHash
        local cache = private.tooltipCache or {}
        private.tooltipCache = cache
        
        -- Check cache (1 second timeout) and skip cache if discounts recently changed
        local now = GetTime()
        local useCached = cache[cacheKey] and not private.discountSettingsChanged
        
        if useCached then
            -- Use cached data
            local cached = cache[cacheKey]
            GameTooltip:AddLine(itemName, 1, 1, 1)
            GameTooltip:AddLine("|cFF00FF00Value Comparison:|r")
            
            -- Auction House Values (Raw and Discounted)
            if cached.hasAuctionValue and cached.auctionValue and cached.auctionValue > 0 then
                local discountedAH = cached.discountedAH or cached.auctionValue  -- Fallback if nil
                discountedAH = max(0, discountedAH)  -- Ensure not negative
                
                local totalDiscountedAH = discountedAH * quantity
                totalDiscountedAH = max(0, totalDiscountedAH)
                
                -- Show raw AH value
                GameTooltip:AddDoubleLine("Auction House Value:", TSMAPI:FormatTextMoney(cached.totalAuctionValue), 1, 1, 1, 1, 1, 1)
                
                -- ALWAYS show discounted AH value when it exists
				if discountedAH < (cached.auctionValue or 0) then
					GameTooltip:AddDoubleLine("  Realistic AH Value:", TSMAPI:FormatTextMoney(totalDiscountedAH), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
					
					-- ADD THIS: Show scan data age for cached data too
					local ageInSeconds = TSM:GetDataAge(itemString)
					local ageCategory, ageText = TSM:GetDataAgeCategory(ageInSeconds)
					local ageColor = ageCategory == "fresh" and "|cFF00FF00" or (ageCategory == "warning" and "|cFFFFFF00" or "|cFFFF0000")
					GameTooltip:AddDoubleLine("  Scan Data Age:", ageColor .. ageText .. "|r", 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
				else
					GameTooltip:AddDoubleLine("  Current AH Value:", TSMAPI:FormatTextMoney(totalDiscountedAH), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
					
					-- Also show age for current values in cached section
					local ageInSeconds = TSM:GetDataAge(itemString)
					local ageCategory, ageText = TSM:GetDataAgeCategory(ageInSeconds)
					local ageColor = ageCategory == "fresh" and "|cFF00FF00" or (ageCategory == "warning" and "|cFFFFFF00" or "|cFFFF0000")
					GameTooltip:AddDoubleLine("  Scan Data Age:", ageColor .. ageText .. "|r", 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
				end
				
                
                if quantity > 1 then
                    GameTooltip:AddDoubleLine("  (per item):", TSMAPI:FormatTextMoney(cached.auctionValue), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
                    if discountedAH < (cached.auctionValue or 0) then
                        GameTooltip:AddDoubleLine("  (realistic per item):", TSMAPI:FormatTextMoney(discountedAH), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
                    else
                        GameTooltip:AddDoubleLine("  (current per item):", TSMAPI:FormatTextMoney(discountedAH), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
                    end
                end
            else
                GameTooltip:AddDoubleLine("Auction House Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
            end
            
            -- Vendor Value
            if cached.hasVendorValue then
                GameTooltip:AddDoubleLine("Vendor Value:", TSMAPI:FormatTextMoney(cached.totalVendorValue), 1, 1, 1, 1, 1, 1)
                if quantity > 1 then
                    GameTooltip:AddDoubleLine("  (per item):", TSMAPI:FormatTextMoney(cached.vendorSell), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddDoubleLine("Vendor Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
            end
            
            -- Destruction Value
            if cached.hasDestructionValue then
                GameTooltip:AddDoubleLine("Destruction Value:", TSMAPI:FormatTextMoney(cached.totalDestructionValue), 1, 1, 1, 1, 1, 1)
                if data.numDestroys > 1 then
                    GameTooltip:AddDoubleLine("  (per cast):", TSMAPI:FormatTextMoney(cached.destructionValue), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddDoubleLine("Destruction Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
            end
            
            -- Show ALL destruction results (even if no pricing data)
            if #cached.destructionDetails > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cFF00FF00Expected Resources (per cast):|r")
                
                for _, matInfo in ipairs(cached.destructionDetails) do
                    local valueText = "|cFF888888No Data|r"
                    if matInfo.value and matInfo.value > 0 then
                        valueText = TSMAPI:FormatTextMoney(matInfo.value)
                    end
                    
                    -- Format quantity to show decimals when appropriate
                    local quantityText
                    if matInfo.quantity and (matInfo.quantity % 1 ~= 0) then -- Has fractional part
                        quantityText = string.format("x%.2f", matInfo.quantity)
                    else
                        quantityText = string.format("x%d", matInfo.quantity or 0)
                    end
                    
                    GameTooltip:AddDoubleLine(
                        format("  %s %s", matInfo.name, quantityText),
                        valueText,
                        1, 1, 1, 1, 1, 1
                    )
                end
            end
            
            -- Add recommendation using cached data
            GameTooltip:AddLine(" ")
            local recommendation, color = private:GetRecommendation(cached, data)
            GameTooltip:AddLine("|cFF00FF00Recommendation:|r")
            GameTooltip:AddDoubleLine("  Best Action:", recommendation, 1, 1, 1, color.r, color.g, color.b)
            
        else
            -- Calculate fresh data
            GameTooltip:AddLine(itemName, 1, 1, 1)
            
            -- Add value comparison section right after item name
            GameTooltip:AddLine("|cFF00FF00Value Comparison:|r")
            
            -- Get auction house value
            local auctionValue = 0
            local hasAuctionValue = false
            local auctionValueFunc = TSMAPI:ParseCustomPrice("DBMarket")
            if auctionValueFunc then
                auctionValue = auctionValueFunc(itemString) or 0
                hasAuctionValue = auctionValue > 0
            end
            local totalAuctionValue = auctionValue * quantity
            
            -- Calculate discounted AH value
            local discountedAH = auctionValue
            if hasAuctionValue then
                if data.spell == GetSpellInfo(TSM.spells.disenchant) then
                    discountedAH = TSM:GetDiscountedAuctionValue(itemString, "disenchant")
                elseif data.spell == GetSpellInfo(TSM.spells.milling) then
                    discountedAH = TSM:GetDiscountedAuctionValue(itemString, "milling") 
                elseif data.spell == GetSpellInfo(TSM.spells.prospect) then
                    discountedAH = TSM:GetDiscountedAuctionValue(itemString, "prospect")
                end
            end
            local totalDiscountedAH = discountedAH * quantity
            
            -- Get vendor sell price
            local vendorSell = 0
            local hasVendorValue = false
            local itemInfo = {TSMAPI:GetSafeItemInfo(itemString)}
            if #itemInfo >= 11 then
                vendorSell = itemInfo[11] or 0
                hasVendorValue = vendorSell > 0
            end
            local totalVendorValue = vendorSell * quantity
            
            -- Get destruction value and details
            local destructionValue = TSM:GetDestroyValue(itemString, data.spell) or 0
            local hasDestructionValue = destructionValue > 0
            local destructionDetails = TSM:GetDestroyDetails(itemString, data.spell) or {}
            local totalDestructionValue = destructionValue * data.numDestroys
            
            -- Cache the calculated data
            cache[cacheKey] = {
                time = now,
                auctionValue = auctionValue,
                hasAuctionValue = hasAuctionValue,
                totalAuctionValue = totalAuctionValue,
                vendorSell = vendorSell,
                hasVendorValue = hasVendorValue,
                totalVendorValue = totalVendorValue,
                destructionValue = destructionValue,
                hasDestructionValue = hasDestructionValue,
                totalDestructionValue = totalDestructionValue,
                destructionDetails = destructionDetails,
                spell = data.spell,
                isSoulbound = private:IsItemSoulbound(data.bag, data.slot),
                discountedAH = discountedAH
            }
            
            -- Show Auction House Values (Raw and Discounted)
			if hasAuctionValue and auctionValue and auctionValue > 0 then
				discountedAH = discountedAH or auctionValue  -- Fallback if nil
				discountedAH = max(0, discountedAH)  -- Ensure not negative
				
				totalDiscountedAH = discountedAH * quantity
				totalDiscountedAH = max(0, totalDiscountedAH)
				
				-- Get scan data age information
				local ageInSeconds = TSM:GetDataAge(itemString)
				local ageCategory, ageText = TSM:GetDataAgeCategory(ageInSeconds)
				local ageColor = ageCategory == "fresh" and "|cFF00FF00" or (ageCategory == "warning" and "|cFFFFFF00" or "|cFFFF0000")
				
				-- Show raw AH value
				GameTooltip:AddDoubleLine("Auction House Value:", TSMAPI:FormatTextMoney(totalAuctionValue), 1, 1, 1, 1, 1, 1)
				
				-- ALWAYS show discounted AH value when it exists
				if math.abs(discountedAH - auctionValue) > 0.01 then
					GameTooltip:AddDoubleLine("  Realistic AH Value:", TSMAPI:FormatTextMoney(totalDiscountedAH), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
					-- NEW: Show scan data age right after realistic value
					GameTooltip:AddDoubleLine("  Scan Data Age:", ageText, 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
				else
					GameTooltip:AddDoubleLine("  Current AH Value:", TSMAPI:FormatTextMoney(totalDiscountedAH), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
					-- Also show age for current values
					GameTooltip:AddDoubleLine("  Scan Data Age:", ageText, 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
				end
				
				if quantity > 1 then
					GameTooltip:AddDoubleLine("  (per item):", TSMAPI:FormatTextMoney(auctionValue), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
					if math.abs(discountedAH - auctionValue) > 0.01 then
						GameTooltip:AddDoubleLine("  (realistic per item):", TSMAPI:FormatTextMoney(discountedAH), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
					else
						GameTooltip:AddDoubleLine("  (current per item):", TSMAPI:FormatTextMoney(discountedAH), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
					end
				end
			else
				GameTooltip:AddDoubleLine("Auction House Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
			end
            
            -- Show Vendor Value
            if hasVendorValue then
                GameTooltip:AddDoubleLine("Vendor Value:", TSMAPI:FormatTextMoney(totalVendorValue), 1, 1, 1, 1, 1, 1)
                if quantity > 1 then
                    GameTooltip:AddDoubleLine("  (per item):", TSMAPI:FormatTextMoney(vendorSell), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddDoubleLine("Vendor Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
            end
            
            -- Show Destruction Value
            if hasDestructionValue then
                GameTooltip:AddDoubleLine("Destruction Value:", TSMAPI:FormatTextMoney(totalDestructionValue), 1, 1, 1, 1, 1, 1)
                if data.numDestroys > 1 then
                    GameTooltip:AddDoubleLine("  (per cast):", TSMAPI:FormatTextMoney(destructionValue), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddDoubleLine("Destruction Value:", "|cFF888888No Data|r", 1, 1, 1, 0.5, 0.5, 0.5)
            end
            
            -- Show ALL destruction results (even if no pricing data)
            if #destructionDetails > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cFF00FF00Expected Resources (per cast):|r")
                
                for _, matInfo in ipairs(destructionDetails) do
                    local valueText = "|cFF888888No Data|r"
                    if matInfo.value and matInfo.value > 0 then
                        valueText = TSMAPI:FormatTextMoney(matInfo.value)
                    end
                    
                    -- Format quantity to show decimals when appropriate
                    local quantityText
                    if matInfo.quantity and (matInfo.quantity % 1 ~= 0) then -- Has fractional part
                        quantityText = string.format("x%.2f", matInfo.quantity)
                    else
                        quantityText = string.format("x%d", matInfo.quantity or 0)
                    end
                    
                    GameTooltip:AddDoubleLine(
                        format("  %s %s", matInfo.name, quantityText),
                        valueText,
                        1, 1, 1, 1, 1, 1
                    )
                end
            end
            
            -- Add recommendation
            GameTooltip:AddLine(" ")
            if TSM.db.profile.enableSuggestions then
                local recommendation, color = private:GetRecommendation(cache[cacheKey], data)
                GameTooltip:AddLine("|cFF00FF00Recommendation:|r")
                GameTooltip:AddDoubleLine("  Best Action:", recommendation, 1, 1, 1, color.r, color.g, color.b)
            else
                local simpleComparison = private:GetSimpleValueComparison(cache[cacheKey])
                GameTooltip:AddLine("|cFF00FF00Value Comparison:|r")
                GameTooltip:AddLine("  " .. simpleComparison, 1, 1, 1, true)
            end
        end
        
         GameTooltip:AddLine(" ")
			local manualOverride = TSM:GetManualOverride(data.itemString)
			if manualOverride then
				local overrideTexts = {
					destroy = "|cFF00FF00Destroy|r",
					auction = "|cFFFFFF00Sell on AH|r", 
					vendor = "|cFFFF8000Vendor|r"
				}
				GameTooltip:AddLine("Manual Override: " .. (overrideTexts[manualOverride] or manualOverride), 1, 1, 1)
			end
        local color = TSMAPI.Design:GetInlineColor("link")
        GameTooltip:AddLine(format(L["%sRight-Click|r to ignore this item for this session. Hold %sshift|r to ignore permanently. You can remove items from permanent ignore in the Destroying options."], color, color), 1, 1, 1, 1, true)
        GameTooltip:AddLine(format("%sShift+Left-Click|r to cycle manual override", color), 1, 1, 1, 1, true)
		private:AddAgeToTooltip(cache[cacheKey], GameTooltip)
        GameTooltip:Show()
    end,
    OnLeave = function()
        GameTooltip:ClearLines()
        GameTooltip:Hide()
    end
}

    local st = TSMAPI:CreateScrollingTable(frame, stCols, handlers, 12)
    st:SetPoint("TOPLEFT", 5, -55)
    st:SetPoint("BOTTOMRIGHT", -5, 30)
    st:SetData({})
    st:DisableSelection(true)
    frame.st = st
    
    -- Destroy button
    local destroyBtn = TSMAPI.GUI:CreateButton(frame, 14, "TSMDestroyButton", true)
    destroyBtn:SetPoint("BOTTOMLEFT", 5, 5)
    destroyBtn:SetPoint("BOTTOMRIGHT", -5, 5)
    destroyBtn:SetHeight(22)
    destroyBtn:SetText(L["Destroy Next"])
    destroyBtn:SetAttribute("type1", "macro")
    destroyBtn:SetAttribute("macrotext1", "")
    destroyBtn:SetScript("PreClick", function()
			if not destroyBtn:IsVisible() or #private.data == 0 then
				destroyBtn:SetAttribute("macrotext1", "")
			else
				local data = private.data[1]
				private.tempData = data
				destroyBtn:SetAttribute("macrotext1", format("/cast %s;\n/use %d %d", data.spell, data.bag, data.slot))
				destroyBtn:Disable()
				TSMAPI:CancelFrame("destroyEnableDelay")
				TSMAPI:CreateTimeDelay("destroyEnableDelay", 3, function() if not UnitCastingInfo("player") and not LootFrame:IsVisible() then destroyBtn:Enable() end end)
				private.highStack = data.numDestroys > 1
				private.currentSpell = data.spell
			end
		end)
    
    frame.destroyBtn = destroyBtn
    
    return frame
end
-- combine partial stacks
function private:Stack()
	local partialStacks = {}
	for bag, slot, itemString, quantity in TSMAPI:GetBagIterator(nil, TSM.db.global.includeSoulbound) do
		local spell, perDestroy = TSM:IsDestroyable(bag, slot, itemString)
		if spell and quantity % perDestroy ~= 0 and not private.ignore[itemString] and not TSM.db.global.ignore[itemString] then
			partialStacks[itemString] = partialStacks[itemString] or {}
			tinsert(partialStacks[itemString], {bag, slot})
		end
	end
	
	for itemString, locations in pairs(partialStacks) do
		for i=#locations, 2, -1 do
			local quantity = select(2, GetContainerItemInfo(unpack(locations[i])))
			local maxStack = select(8, GetItemInfo(itemString))
			if quantity == 0 or quantity == maxStack then break end
			
			for j=1, i-1 do
				local targetQuantity = select(2, GetContainerItemInfo(unpack(locations[j])))
				if targetQuantity ~= maxStack then
					PickupContainerItem(unpack(locations[i]))
					PickupContainerItem(unpack(locations[j]))
				end
			end
		end
	end
end

local isDelayed
function private:UpdateST(forceShow)
	-- Reset hidden flag if forceShow is true
	if forceShow then
		private.hidden = nil
	end
	
	if private.hidden then 
		TSM:Print("Frame is hidden for this session. Use /tsm destroy to show again.")
		return 
	end
	
	if (not private.frame or not private.frame:IsVisible()) and not forceShow and not isDelayed then
		TSMAPI:CreateTimeDelay("destroyBagUpdateDelay2", 1, function() isDelayed = true private:UpdateST() isDelayed = nil end)
		return
	end
	if InCombatLockdown() then return end
	
	if TSM.db.global.autoStack then
		private:Stack()
	end
	
	local stData = {}
	local foundItems = false
	
	for bag, slot, itemString, quantity in TSMAPI:GetBagIterator(nil, TSM.db.global.includeSoulbound) do
		if not private.ignore[itemString] and not TSM.db.global.ignore[itemString] then
			local spell, perDestroy = TSM:IsDestroyable(bag, slot, itemString)
			local link = GetContainerItemLink(bag, slot)
			if spell and quantity >= perDestroy then
				foundItems = true
				local row = {
					cols = {
						{
							value = link,
						},
						{
							value = quantity
						},
					},
					itemString = itemString,
					link = link,
					quantity = quantity,
					bag = bag,
					slot = slot,
					spell = spell,
					perDestroy = perDestroy,
					numDestroys = floor(quantity/perDestroy),
				}
				tinsert(stData, row)
			end
		end
	end
	
	-- Apply filters and sorting
	stData = private:ApplyFilters(stData)
	
	if #stData == 0 then
		if forceShow then
			if foundItems then
				TSM:Print(L["No items match current filters."])
			else
				TSM:Print(L["Nothing to destroy in your bags."])
			end
		end
		if private.frame and private.frame.destroyBtn then
			private.frame.destroyBtn:Disable()
		end
		-- NEVER hide the frame when forceShow is true or when filtering/sorting
		if not forceShow and private.frame and not foundItems then
			private.frame:Hide()
		elseif private.frame and forceShow then
			-- Keep frame visible but empty when forceShow is true
			private.frame:Show()
		end
	else
		-- Always show if we have data OR forceShow is true
		if private.frame and not private.frame:IsVisible() then
			TSMAPI:CancelFrame("destroyEnableDelay")
			if private.frame.destroyBtn then
				private.frame.destroyBtn:Enable()
			end
			private.frame:Show()
		elseif private.frame and private.frame.destroyBtn then
			private.frame.destroyBtn:Enable()
		end
	end
	
	if private.frame and private.frame.st then
		private.data = CopyTable(stData)
		private.frame.st:SetData(stData)
	end
end

function GUI:UpdateST(forceShow)
    private:UpdateST(forceShow)
end

function GUI:UNIT_SPELLCAST_INTERRUPTED(_, unit, spell)
    if unit == "player" and private.frame and private.frame:IsVisible() and private.frame.destroyBtn then
        TSMAPI:CancelFrame("destroyEnableDelay")
        private.frame.destroyBtn:Enable()
        private.tempData = nil
    end
end

function private:LootOpened()
	if not private.currentSpell then return end
	local temp = {result={}, time=time()}
	for bag, slot, itemString, quantity, locked in TSMAPI:GetBagIterator(nil, TSM.db.global.includeSoulbound) do
		if locked and TSM:IsDestroyable(bag, slot, itemString) then
			temp.item = itemString
			break
		end
	end
	if temp.item and GetNumLootItems() > 0 then
		for i=1, GetNumLootItems() do
			local itemString = TSMAPI:GetItemString(GetLootSlotLink(i))
			local quantity = select(3, GetLootSlotInfo(i)) or 0
			if itemString and quantity > 0 then
				temp.result[itemString] = quantity
			end
		end
		TSM.db.global.history[private.currentSpell] = TSM.db.global.history[private.currentSpell] or {}
		tinsert(TSM.db.global.history[private.currentSpell], temp)
		TSM.Options:UpdateLogST()
	end
	private.currentSpell = nil
end

function private:LootChanged()
    if not private.tempData then return end
    
    -- Enable the button when loot window closes OR when we're not casting
    if not LootFrame:IsVisible() then
        TSMAPI:CancelFrame("destroyEnableDelay")
        if private.frame and private.frame:IsVisible() and private.frame.destroyBtn then
            private.frame.destroyBtn:Enable()
        end
        private.tempData = nil
    elseif private.highStack and GetNumLootItems() <= 1 then
        -- For high stacks, enable when only 1 loot item remains
        TSMAPI:CancelFrame("destroyEnableDelay")
        if private.frame and private.frame:IsVisible() and private.frame.destroyBtn then
            private.frame.destroyBtn:Enable()
        end
    end
end

function private:IsItemSoulbound(bag, slot)
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "TSMSoulboundScanTooltip", UIParent, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    scanTooltip:ClearLines()
    scanTooltip:SetBagItem(bag, slot)
    
    for i=2, scanTooltip:NumLines() do
        local text = _G["TSMSoulboundScanTooltipTextLeft"..i] and _G["TSMSoulboundScanTooltipTextLeft"..i]:GetText()
        if text then
            -- ONLY treat as soulbound if it's actually soulbound (not bind-on-equip)
            if text == ITEM_SOULBOUND or text == ITEM_BIND_QUEST then
                return true
            -- Bind-on-equip items CAN be sold on AH, so don't treat as soulbound
            elseif text == ITEM_BIND_ON_EQUIP then
                return false
            end
        end
    end
    return false
end

function private:GetRecommendation(cached, data)
    if not TSM.db.profile.enableSuggestions then
        return "Make Your Own Decision", {r = 0.5, g = 0.5, b = 0.5}
    end
    
    -- Check for manual override first
    local manualOverride = TSM:GetManualOverride(data.itemString)
    if manualOverride and manualOverride ~= "auto" then
        local overrideTexts = {
            destroy = "Destroy (Manual Override)",
            auction = "Sell on AH (Manual Override)",
            vendor = "Vendor (Manual Override)"
        }
        local colors = {
            destroy = {r = 0, g = 1, b = 0},
            auction = {r = 1, g = 1, b = 0}, 
            vendor = {r = 1, g = 0.5, b = 0}
        }
        return overrideTexts[manualOverride] or "Manual Override", colors[manualOverride] or {r = 0.5, g = 0.5, b = 0.5}
    end
	
    local isSoulbound = cached.isSoulbound
    if isSoulbound then
        -- Soulbound items cannot be sold on AH, so ignore AH value for recommendations
        cached.hasAuctionValue = false
        cached.totalAuctionValue = 0
        cached.auctionValue = 0
    end
	
    -- Use DISCOUNTED AH value for comparisons, not raw AH value
    local auctionValue = cached.discountedAH and (cached.discountedAH * (data.quantity or 1)) or (cached.totalAuctionValue or 0)
    local vendorValue = cached.totalVendorValue or 0
    local destructionValue = cached.totalDestructionValue or 0
    local hasAuction = cached.hasAuctionValue
    local hasVendor = cached.hasVendorValue
    local hasDestruction = cached.hasDestructionValue
    local isSoulbound = cached.isSoulbound
    
    -- Check data freshness
    local dataIsFresh = true
    
    -- SOULBOUND ITEMS: Only compare vendor vs destruction
    if isSoulbound then
        if not hasDestruction then
            return "Scan Auction - No destruction data", {r = 1, g = 0, b = 0}
        end
        
        if destructionValue > vendorValue * 1.1 then -- 10% buffer for destruction effort
            return "Destroy", {r = 0, g = 1, b = 0}
        elseif destructionValue > vendorValue then
            return "Destroy (slight profit)", {r = 0, g = 0.8, b = 0}
        else
            return "Vendor", {r = 1, g = 0.5, b = 0}
        end
    end
    
    -- NO AUCTION DATA: Always suggest scanning first
    if not hasAuction then
        return "Scan Auction - No price data", {r = 1, g = 0, b = 0}
    end
    
    -- DATA OUTDATED: Suggest rescan
    if not dataIsFresh then
        return "Scan Auction - Data outdated", {r = 1, g = 0.5, b = 0}
    end
    
    -- DISENCHANTING: Compare vendor vs destruction vs REALISTIC AH value
    if data.spell == GetSpellInfo(TSM.spells.disenchant) then
        if not hasDestruction then
            return "Scan Auction - No destruction data", {r = 1, g = 0, b = 0}
        end
        
        if destructionValue > vendorValue and destructionValue > auctionValue then
            return "Destroy", {r = 0, g = 1, b = 0}
        elseif vendorValue > destructionValue and vendorValue > auctionValue then
            return "Vendor", {r = 1, g = 0.5, b = 0}
        else
            return "Sell on AH", {r = 1, g = 1, b = 0}
        end
    
    -- MILLING/PROSPECTING: Compare realistic raw material value vs destruction outputs
    elseif data.spell == GetSpellInfo(TSM.spells.milling) or data.spell == GetSpellInfo(TSM.spells.prospect) then
        if not hasDestruction then
            return "Scan Auction - No destruction data", {r = 1, g = 0, b = 0}
        end
        
        -- For milling/prospecting, compare realistic raw material value vs destruction outputs
        local rawMaterialValue = auctionValue
        local destructionOutputValue = destructionValue
        
        if destructionOutputValue > rawMaterialValue * 1.2 then -- 20% profit margin
            return "Destroy", {r = 0, g = 1, b = 0}
        elseif destructionOutputValue > rawMaterialValue then
            return "Destroy (slight profit)", {r = 0, g = 0.8, b = 0}
        elseif rawMaterialValue > vendorValue then
            return "Sell Raw Materials", {r = 1, g = 1, b = 0}
        else
            return "Vendor", {r = 1, g = 0.5, b = 0}
        end
    end
    
    -- FALLBACK: Simple comparison using REALISTIC AH value
    local bestValue = math.max(auctionValue, vendorValue, destructionValue)
    if bestValue == auctionValue then
        return "Sell on AH", {r = 1, g = 1, b = 0}
    elseif bestValue == destructionValue then
        return "Destroy", {r = 0, g = 1, b = 0}
    else
        return "Vendor", {r = 1, g = 0.5, b = 0}
    end
end

function private:GetCurrentRecommendedAction(data)
    -- Calculate values to determine what would be auto-recommended
    local auctionValueFunc = TSMAPI:ParseCustomPrice("DBMarket")
    local auctionValue = auctionValueFunc and auctionValueFunc(data.itemString) or 0
    local totalAuctionValue = auctionValue * data.quantity
    
    -- Get discounted AH value
    local discountedAH = auctionValue
    if data.spell == GetSpellInfo(TSM.spells.disenchant) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "disenchant")
    elseif data.spell == GetSpellInfo(TSM.spells.milling) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "milling") 
    elseif data.spell == GetSpellInfo(TSM.spells.prospect) then
        discountedAH = TSM:GetDiscountedAuctionValue(data.itemString, "prospect")
    end
    local totalDiscountedAH = discountedAH * data.quantity
    
    -- Get vendor value
    local vendorSell = 0
    local itemInfo = {TSMAPI:GetSafeItemInfo(data.itemString)}
    if #itemInfo >= 11 then
        vendorSell = itemInfo[11] or 0
    end
    local totalVendorValue = vendorSell * data.quantity
    
    -- Get destruction value
    local destructionValue = TSM:GetDestroyValue(data.itemString, data.spell) or 0
    local totalDestructionValue = destructionValue * data.numDestroys
    
    -- Check if soulbound
    local isSoulbound = private:IsItemSoulbound(data.bag, data.slot)
    
    -- Determine best action
    if isSoulbound then
        if totalDestructionValue > totalVendorValue then
            return "destroy"
        else
            return "vendor"
        end
    else
        local bestValue = math.max(totalDiscountedAH, totalVendorValue, totalDestructionValue)
        if bestValue == totalDiscountedAH then
            return "auction"
        elseif bestValue == totalDestructionValue then
            return "destroy"
        else
            return "vendor"
        end
    end
end