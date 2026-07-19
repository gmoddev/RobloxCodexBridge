--!strict

-- UniqueIdHelpers: Centralized utilities for managing the CodexUniqueID attribute
-- with backwards compatibility for the old "_CodexUniqueId" and "uniqueId" attributes.

local Log = require(script.Parent.Parent.Log)

local UniqueIdHelpers = {}

-- Attribute name constants
local NEW_ATTRIBUTE = "CodexUniqueID"
local LEGACY_ATTRIBUTES = {
	"_CodexUniqueId",
	"uniqueId",
}

-- Get the unique ID from an instance with backwards compatibility
-- Returns: (uniqueId: string?, wasMigrated: boolean)
function UniqueIdHelpers.getUniqueId(instance: Instance): (string?, boolean)
	-- First, check for the new attribute
	local newId = instance:GetAttribute(NEW_ATTRIBUTE)
	if newId and typeof(newId) == "string" then
		return newId, false
	end

	-- Fall back to legacy attributes.
	for _, LegacyAttribute in ipairs(LEGACY_ATTRIBUTES) do
		local LegacyId = instance:GetAttribute(LegacyAttribute)
		if LegacyId and typeof(LegacyId) == "string" then
			Log.debug(
				"[UniqueIdHelpers] Migrating",
				LegacyAttribute,
				"to",
				NEW_ATTRIBUTE,
				"for:",
				instance:GetFullName()
			)
			instance:SetAttribute(NEW_ATTRIBUTE, LegacyId)
			return LegacyId, true
		end
	end

	return nil, false
end

-- Set the unique ID on an instance (uses new attribute name)
function UniqueIdHelpers.setUniqueId(instance: Instance, uniqueId: string)
	instance:SetAttribute(NEW_ATTRIBUTE, uniqueId)
end

-- Get the attribute name to use (returns the new attribute name)
function UniqueIdHelpers.getAttributeName(): string
	return NEW_ATTRIBUTE
end

-- Get the legacy attribute name (for reference/documentation)
function UniqueIdHelpers.getLegacyAttributeName(): string
	return LEGACY_ATTRIBUTES[1]
end

function UniqueIdHelpers.isInternalUniqueIdAttribute(attributeName: string): boolean
	if attributeName == NEW_ATTRIBUTE then
		return true
	end

	for _, LegacyAttribute in ipairs(LEGACY_ATTRIBUTES) do
		if attributeName == LegacyAttribute then
			return true
		end
	end

	return false
end

return UniqueIdHelpers
