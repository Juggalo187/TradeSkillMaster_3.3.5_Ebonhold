-- ------------------------------------------------------------------------------ --
--                           TradeSkillMaster_Destroying                          --
--           http://www.curse.com/addons/wow/tradeskillmaster_destroying          --
--                                                                                --
--             A TradeSkillMaster Addon (http://tradeskillmaster.com)             --
--    All Rights Reserved* - Detailed license information included with addon.    --
-- ------------------------------------------------------------------------------ --

-- register this file with Ace Libraries
local TSM = select(2, ...)
TSM = LibStub("AceAddon-3.0"):NewAddon(TSM, "TSM_Destroying", "AceConsole-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("TradeSkillMaster_Destroying") -- loads the localization table
local private = {}
TSM.destroyCache = {}

--Professions--
TSM.spells = {
	milling = 51005,
	prospect = 31252,
	disenchant = 13262,
}

local savedDBDefaults = {
	global = {
		history = {},
		ignore = {},
		autoStack = true,
		autoShow = true,
		timeFormat = "ago",
		deMaxQuality = 3,
		logDays = 3,
		includeSoulbound = false,
	},
	profile = {
		destroyValueSource = "DBMarket",
		sortBy = "suggestion",
		enableSuggestions = true,
		discountPercentages = nil,
		showOnlyDestroy = false,
		manualOverrides = {},
	},
}

-- Called once the player has loaded WOW.
function TSM:OnInitialize()
	-- create shortcuts to all the modules
	for moduleName, module in pairs(TSM.modules) do
		TSM[moduleName] = module
	end
	
	-- load the savedDB into TSM.db
	TSM.db = LibStub:GetLibrary("AceDB-3.0"):New("TradeSkillMaster_DestroyingDB", savedDBDefaults, true)

	-- Initialize suggestion system (enabled by default)
	if TSM.db.profile.enableSuggestions == nil then
		TSM.db.profile.enableSuggestions = true
	end
	
	-- Initialize discount percentages with defaults if not set
	if not TSM.db.profile.discountPercentages then
		TSM.db.profile.discountPercentages = TSM:GetDefaultDiscounts()
	end

	-- register this module with TSM
	TSM:RegisterModule()
end

-- registers this module with TSM by first setting all fields and then calling TSMAPI:NewModule().
function TSM:RegisterModule()
	TSM.icons = {
		{side="module", desc="Destroying", slashCommand = "destroying", callback="Options:Load", icon="Interface\\Icons\\INV_Gizmo_RocketBoot_Destroyed_02"},
	}
	TSM.slashCommands = {
		{key="destroy", label=L["Opens the Destroying frame if there's stuff in your bags to be destroyed."], callback="GUI:ShowFrame"},
	}

	TSMAPI:NewModule(TSM)
end

function TSM:GetDataAge(itemString)
    if not TSMAPI then 
        return 999 
    end
    
    if not TradeSkillMaster_AuctionDBDB then
        return 999
    end
    
    local realm = GetRealmName()
    local faction = UnitFactionGroup("player")
    local factionrealmKey = faction .. " - " .. realm
    
    if not TradeSkillMaster_AuctionDBDB.factionrealm then
        return 999
    end
    
    local factionrealmData = TradeSkillMaster_AuctionDBDB.factionrealm[factionrealmKey]
    if not factionrealmData then
        return 999
    end
    
    local lastCompleteScan = factionrealmData.lastCompleteScan
    if not lastCompleteScan or lastCompleteScan == 0 then
        return 999
    end
    
    local currentTime = time()
    local ageInSeconds = currentTime - lastCompleteScan
    
    return ageInSeconds
end

function TSM:GetDataAgeCategory(ageInSeconds)
    if not ageInSeconds or ageInSeconds == 999 then
        return "old", "No data"
    end
    
    local ageInMinutes = ageInSeconds / 60
    local ageInHours = ageInMinutes / 60
    local ageInDays = ageInHours / 24
    
    -- Format the time display
    local ageText
    if ageInDays >= 1 then
        ageText = floor(ageInDays) .. " days"
    elseif ageInHours >= 1 then
        ageText = floor(ageInHours) .. " hours"
    else
        ageText = max(1, floor(ageInMinutes)) .. " minutes"
    end
    
    if ageInDays <= 2 then
        return "fresh", ageText
    elseif ageInDays <= 7 then
        return "warning", ageText
    else
        return "old", ageText
    end
end

function TSM:GetDefaultDiscounts()
    return {
        disenchant = { fresh = 75, warning = 80, old = 90 },    -- 25%, 20%, 10% discounts
        milling = { fresh = 0, warning = 15, old = 40 },       -- 0%, 15%, 40% discounts  
        prospect = { fresh = 0, warning = 10, old = 30 }       -- 0%, 10%, 30% discounts
    }
end

function TSM:GetAgeBasedDiscount(ageCategory, profession)
    local defaults = TSM:GetDefaultDiscounts()
    local discounts = TSM.db.profile.discountPercentages or defaults
    
    local discountPercent = 0
    
    if discounts[profession] and discounts[profession][ageCategory] then
        discountPercent = discounts[profession][ageCategory] or 0
        
        -- Convert from whole number percentage to decimal
        discountPercent = discountPercent / 100
        
        -- Ensure value is between 0 and 1
        discountPercent = max(0, min(1, discountPercent))
    else
        -- Fallback to defaults (convert to decimal)
        discountPercent = (defaults[profession] and defaults[profession][ageCategory] or 0) / 100
    end
    
    local multiplier = 1 - discountPercent
    
    return multiplier
end

function TSM:GetDiscountedAuctionValue(itemString, profession)
    if not profession then 
        return 0 
    end
    
    -- Get raw auction value
    local auctionValueFunc = TSMAPI:ParseCustomPrice("DBMarket")
    if not auctionValueFunc then
        return 0
    end
    
    local rawAuctionValue = auctionValueFunc(itemString)
    
    if not rawAuctionValue or rawAuctionValue <= 0 then 
        return 0 
    end
    
    -- Get data age - handle case where AuctionDB might not be available
    local ageInDays = TSM:GetDataAge(itemString)
    local ageCategory
    
    if ageInDays == 999 then
        -- No AuctionDB data available, use default "old" category
        ageCategory = "old"
    else
        ageCategory = TSM:GetDataAgeCategory(ageInDays)
    end
    
    -- Get discount multiplier (1 - discount percentage)
    local multiplier = TSM:GetAgeBasedDiscount(ageCategory, profession)
    
    local discountedValue = rawAuctionValue * multiplier
    
    return floor(discountedValue + 0.5)
end

function TSM:GetDestroyValue(itemString, spell)
    if spell == GetSpellInfo(TSM.spells.disenchant) then
        return TSM:CalculateDisenchantValue(itemString)
    elseif spell == GetSpellInfo(TSM.spells.milling) then
        return TSM:CalculateMillValue(itemString)
    elseif spell == GetSpellInfo(TSM.spells.prospect) then
        return TSM:CalculateProspectValue(itemString)
    end
    return 0
end

function TSM:CalculateDisenchantValue(itemString)
    local discountedAH = TSM:GetDiscountedAuctionValue(itemString, "disenchant")
    local rawAH = TSMAPI:ParseCustomPrice("DBMarket") and TSMAPI:ParseCustomPrice("DBMarket")(itemString) or 0
	
    local _, itemLink, quality, ilvl, _, iType = TSMAPI:GetSafeItemInfo(itemString)
    local WEAPON, ARMOR = GetAuctionItemClasses()
    if not itemString or TSMAPI.DisenchantingData.notDisenchantable[itemString] or not (iType == ARMOR or iType == WEAPON) then 
        return 0 
    end

    local value = 0
    for _, data in ipairs(TSMAPI.DisenchantingData.disenchant) do
        for item, itemData in pairs(data) do
            if item ~= "desc" and itemData.itemTypes[iType] and itemData.itemTypes[iType][quality] then
                for _, deData in ipairs(itemData.itemTypes[iType][quality]) do
                    if ilvl >= deData.minItemLevel and ilvl <= deData.maxItemLevel then
                        -- Use configured price source with DBMarket fallback
                        local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
                        local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
                        local matValue = matValueFunc and matValueFunc(item) or 0
                        
                        -- Calculate weighted average based on probabilities
                        local probability = deData.probability or 1.0
                        value = value + (matValue * deData.amountOfMats * probability)
                    end
                end
            end
        end
    end
    return value
end

function TSM:CalculateMillValue(itemString)
	local discountedAH = TSM:GetDiscountedAuctionValue(itemString, "milling")
    local value = 0
    for _, targetItem in ipairs(TSMAPI:GetConversionTargetItems("mill")) do
        local herbs = TSMAPI:GetItemConversions(targetItem)
        if herbs[itemString] then
            -- Use configured price source with DBMarket fallback
            local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
            local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
            local matValue = matValueFunc and matValueFunc(targetItem) or 0
            
            -- For milling, we can get MULTIPLE materials simultaneously
            -- Sum all possible outputs (common + rare pigments)
            value = value + (matValue * herbs[itemString].rate)
        end
    end
    return value
end

function TSM:CalculateProspectValue(itemString)
	 local discountedAH = TSM:GetDiscountedAuctionValue(itemString, "prospect")
    local value = 0
    for _, targetItem in ipairs(TSMAPI:GetConversionTargetItems("prospect")) do
        local gems = TSMAPI:GetItemConversions(targetItem)
        if gems[itemString] then
            -- Use configured price source with DBMarket fallback
            local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
            local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
            local matValue = matValueFunc and matValueFunc(targetItem) or 0
            
            -- For prospecting, we can get MULTIPLE materials simultaneously  
            -- Sum all possible outputs (common gems + rare gems)
            value = value + (matValue * gems[itemString].rate)
        end
    end
    return value
end

function TSM:GetDestroyDetails(itemString, spell)
    local details = {}
    
    if spell == GetSpellInfo(TSM.spells.disenchant) then
        local _, itemLink, quality, ilvl, _, iType = TSMAPI:GetSafeItemInfo(itemString)
        local WEAPON, ARMOR = GetAuctionItemClasses()
        
        if itemString and not TSMAPI.DisenchantingData.notDisenchantable[itemString] and (iType == ARMOR or iType == WEAPON) then
            for _, deData in ipairs(TSMAPI.DisenchantingData.disenchant) do
                for matItem, itemData in pairs(deData) do
                    if matItem ~= "desc" and itemData.itemTypes[iType] and itemData.itemTypes[iType][quality] then
                        for _, deInfo in ipairs(itemData.itemTypes[iType][quality]) do
                            if ilvl >= deInfo.minItemLevel and ilvl <= deInfo.maxItemLevel then
                                -- Use configured price source with DBMarket fallback
                                local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
                                local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
                                local matValue = matValueFunc and matValueFunc(matItem) or 0
                                local matName = select(1, TSMAPI:GetSafeItemInfo(matItem)) or matItem
                                local probability = deInfo.probability or 1.0
                                local totalMatValue = matValue * deInfo.amountOfMats * probability
                                
                                tinsert(details, {
                                    name = matName,
                                    quantity = deInfo.amountOfMats * probability, -- Expected quantity considering probability
                                    value = totalMatValue
                                })
                            end
                        end
                    end
                end
            end
        end
        
    elseif spell == GetSpellInfo(TSM.spells.milling) then
        for _, targetItem in ipairs(TSMAPI:GetConversionTargetItems("mill")) do
            local herbs = TSMAPI:GetItemConversions(targetItem)
            if herbs[itemString] then
                -- Use configured price source with DBMarket fallback
                local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
                local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
                local matValue = matValueFunc and matValueFunc(targetItem) or 0
                local matName = select(1, TSMAPI:GetSafeItemInfo(targetItem)) or targetItem
                local totalMatValue = matValue * herbs[itemString].rate
                
                tinsert(details, {
                    name = matName,
                    quantity = herbs[itemString].rate,
                    value = totalMatValue
                })
            end
        end
        
    elseif spell == GetSpellInfo(TSM.spells.prospect) then
        for _, targetItem in ipairs(TSMAPI:GetConversionTargetItems("prospect")) do
            local gems = TSMAPI:GetItemConversions(targetItem)
            if gems[itemString] then
                -- Use configured price source with DBMarket fallback
                local priceSource = TSM.db.profile.destroyValueSource or "DBMarket"
                local matValueFunc = TSMAPI:ParseCustomPrice(priceSource)
                local matValue = matValueFunc and matValueFunc(targetItem) or 0
                local matName = select(1, TSMAPI:GetSafeItemInfo(targetItem)) or targetItem
                local totalMatValue = matValue * gems[itemString].rate
                
                tinsert(details, {
                    name = matName,
                    quantity = gems[itemString].rate,
                    value = totalMatValue
                })
            end
        end
    end
    
    return details
end

-- Helper function to get current enchanting skill level
function private:GetCurrentEnchantingSkill()
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank = GetSkillLineInfo(i)
        if skillName and not isHeader then
            if skillName == GetSpellInfo(TSM.spells.disenchant) or skillName == "Enchanting" then
                return skillRank or 0
            end
        end
    end
    return 0
end

-- Helper function to determine required skill level for disenchanting
function private:GetRequiredDisenchantSkill(quality, itemLevel, itemClass, itemSubClass)
    -- Skill requirements based SOLELY on item level (not quality)
    if itemLevel <= 20 then return 1 end
    if itemLevel <= 25 then return 25 end
    if itemLevel <= 30 then return 50 end
    if itemLevel <= 35 then return 75 end
    if itemLevel <= 40 then return 100 end
    if itemLevel <= 45 then return 125 end
    if itemLevel <= 50 then return 150 end
    if itemLevel <= 55 then return 175 end
    if itemLevel <= 60 then return 200 end
    if itemLevel <= 65 then return 225 end
    if itemLevel <= 99 then return 275 end
    if itemLevel <= 120 then return 300 end
    if itemLevel <= 151 then return 325 end
    if itemLevel <= 164 then return 350 end
    if itemLevel <= 200 then return 375 end
    -- For WotLK content, 350 is typically the max required
    return 1 -- Default minimum (fallback)
end

-- determines if an item is millable or prospectable
local scanTooltip
-- Remove this line: local destroyCache = {}

function TSM:IsDestroyable(bag, slot, itemString)
    if TSM.destroyCache[itemString] then
        return unpack(TSM.destroyCache[itemString])
    end

    local _, link, quality, itemLevel, _, iType, _, _, _, _, _, itemClass, itemSubClass = TSMAPI:GetSafeItemInfo(itemString)
    local WEAPON, ARMOR = GetAuctionItemClasses()
    
    -- Check for disenchantable items
    if itemString and not TSMAPI.DisenchantingData.notDisenchantable[itemString] and (iType == ARMOR or iType == WEAPON) and (quality >= 2 and quality <= TSM.db.global.deMaxQuality) then
        if IsSpellKnown(TSM.spells.disenchant) then
            -- Check if player has sufficient skill to disenchant this item
            local requiredSkill = private:GetRequiredDisenchantSkill(quality, itemLevel, itemClass, itemSubClass)
            local currentSkill = private:GetCurrentEnchantingSkill()
            
            if currentSkill >= requiredSkill then
                TSM.destroyCache[itemString] = {GetSpellInfo(TSM.spells.disenchant), 1}
                return unpack(TSM.destroyCache[itemString])
            end
        end
        TSM.destroyCache[itemString] = {}
        return unpack(TSM.destroyCache[itemString] or {})
    end
    
    -- Check for milling/prospecting (existing code)
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "TSMDestroyScanTooltip", UIParent, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    scanTooltip:ClearLines()
    scanTooltip:SetBagItem(bag, slot)

    for i=1, scanTooltip:NumLines() do
        local text = _G["TSMDestroyScanTooltipTextLeft"..i] and _G["TSMDestroyScanTooltipTextLeft"..i]:GetText()
        if text == ITEM_MILLABLE then
            TSM.destroyCache[itemString] = {IsSpellKnown(TSM.spells.milling) and GetSpellInfo(TSM.spells.milling), 5}
            break
        elseif text == ITEM_PROSPECTABLE then
            TSM.destroyCache[itemString] = {IsSpellKnown(TSM.spells.prospect) and GetSpellInfo(TSM.spells.prospect), 5}
            break
        end
    end
    return unpack(TSM.destroyCache[itemString] or {})
end

function TSM:SetManualOverride(itemString, action)
    TSM.db.profile.manualOverrides = TSM.db.profile.manualOverrides or {}
    TSM.db.profile.manualOverrides[itemString] = action
end

function TSM:GetManualOverride(itemString)
    TSM.db.profile.manualOverrides = TSM.db.profile.manualOverrides or {}
    return TSM.db.profile.manualOverrides[itemString]
end

function TSM:ClearManualOverride(itemString)
    TSM.db.profile.manualOverrides = TSM.db.profile.manualOverrides or {}
    TSM.db.profile.manualOverrides[itemString] = nil
end

function TSM:CycleManualOverride(itemString, currentRecommendedAction)
    local actions
    if TSM.db.profile.enableSuggestions then
        -- With suggestions enabled, include "auto" in the cycle
        actions = {"destroy", "auction", "vendor", "auto"}
    else
        -- With suggestions disabled, only cycle through manual actions
        actions = {"destroy", "auction", "vendor"}
    end
    
    local currentOverride = TSM:GetManualOverride(itemString)
    
    if not currentOverride then
        -- No override yet, set to first action
        TSM:SetManualOverride(itemString, actions[1])
        return actions[1]
    else
        local currentIndex = 1
        for i, action in ipairs(actions) do
            if action == currentOverride then
                currentIndex = i
                break
            end
        end
        
        local nextIndex = (currentIndex % #actions) + 1
        local nextAction = actions[nextIndex]
        
        if nextAction == "auto" then
            TSM:ClearManualOverride(itemString)
            return "auto"
        else
            TSM:SetManualOverride(itemString, nextAction)
            return nextAction
        end
    end
end