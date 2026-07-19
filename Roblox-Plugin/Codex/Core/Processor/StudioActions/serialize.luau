--!strict
-- serialize: Capture complete instance state for rollback undo
-- Used by operation-based rollback system (Task 048 - LEMON-1052)
-- Captures instance, properties, attributes, script source, and all descendants

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local PropertySerializer = require(Codex.Util.PropertySerializer)

-- Properties to serialize for different class types
local SERIALIZABLE_PROPERTIES = {
	BasePart = { "Color", "Size", "CFrame", "Anchored", "CanCollide", "Transparency", "Material", "BrickColor" },
	Light = { "Color", "Brightness", "Enabled", "Range", "Shadows" },
	Decal = { "Texture", "Color3", "Transparency" },
	Sound = { "SoundId", "Volume", "Looped", "PlayOnRemove", "PlaybackSpeed" },
	ParticleEmitter = { "Color", "Size", "Texture", "Rate", "Lifetime", "Speed", "Enabled" },
	BillboardGui = { "Size", "StudsOffset", "AlwaysOnTop", "Enabled" },
	SurfaceGui = { "Face", "AlwaysOnTop", "Enabled" },
	Model = {}, -- PrimaryPart handled via _PrimaryPartUniqueId attribute

	-- GUI classes (required for rollback of deleted UI elements)
	GuiObject = {
		"Position", "Size", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency",
		"BorderColor3", "BorderSizePixel", "Visible", "ZIndex", "LayoutOrder",
		"Rotation", "SizeConstraint", "AutomaticSize", "ClipsDescendants",
	},
	ScreenGui = { "DisplayOrder", "Enabled", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior" },
	ImageLabel = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "TileSize", "SliceCenter", "ImageRectOffset", "ImageRectSize" },
	ImageButton = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "TileSize", "SliceCenter", "ImageRectOffset", "ImageRectSize" },
	TextLabel = { "Text", "TextColor3", "TextSize", "Font", "TextScaled", "TextWrapped", "TextXAlignment", "TextYAlignment", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency", "RichText" },
	TextButton = { "Text", "TextColor3", "TextSize", "Font", "TextScaled", "TextWrapped", "TextXAlignment", "TextYAlignment", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency", "RichText" },
	TextBox = { "Text", "PlaceholderText", "TextColor3", "TextSize", "Font", "TextScaled", "TextWrapped", "TextXAlignment", "TextYAlignment", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency", "ClearTextOnFocus", "MultiLine" },
	ScrollingFrame = { "CanvasSize", "CanvasPosition", "ScrollBarThickness", "ScrollBarImageColor3", "ScrollingDirection", "ScrollBarImageTransparency", "ElasticBehavior" },
	ViewportFrame = { "CurrentCamera", "ImageColor3", "ImageTransparency", "Ambient", "LightColor", "LightDirection" },
	UICorner = { "CornerRadius" },
	UIStroke = { "Color", "Thickness", "Transparency", "ApplyStrokeMode", "LineJoinMode" },
	UIListLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "Padding", "SortOrder", "HorizontalFlex", "VerticalFlex", "Wraps" },
	UIGridLayout = { "CellSize", "CellPadding", "FillDirection", "HorizontalAlignment", "VerticalAlignment", "SortOrder", "FillDirectionMaxCells" },
	UIPadding = { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UIScale = { "Scale" },
	UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	UISizeConstraint = { "MinSize", "MaxSize" },
	UITextSizeConstraint = { "MinTextSize", "MaxTextSize" },
	UIGradient = { "Color", "Offset", "Rotation", "Transparency" },
	UIFlexItem = { "FlexMode", "GrowRatio", "ShrinkRatio" },
}

-- Serialize a single instance (not descendants)
local function serializeInstance(instance: Instance): {
	className: string,
	name: string,
	uniqueId: string?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?,
	source: string?,
}
	local uniqueId = UniqueIdHelpers.getUniqueId(instance)

	local data = {
		className = instance.ClassName,
		name = instance.Name,
		uniqueId = uniqueId,
		properties = nil :: { [string]: any }?,
		attributes = nil :: { [string]: any }?,
		source = nil :: string?,
	}

	-- Serialize attributes (excluding internal ones)
	local attributes = {}
	local hasAttributes = false
	for name, value in pairs(instance:GetAttributes()) do
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(name) then
			attributes[name] = value
			hasAttributes = true
		end
	end
	-- Handle PrimaryPart for Models (serialize as _PrimaryPartUniqueId attribute)
	if instance:IsA("Model") then
		local model = instance :: Model
		if model.PrimaryPart then
			local primaryPartUniqueId = UniqueIdHelpers.getUniqueId(model.PrimaryPart)
			if primaryPartUniqueId then
				attributes._PrimaryPartUniqueId = primaryPartUniqueId
				hasAttributes = true
			end
		end
	end

	if hasAttributes then
		data.attributes = attributes
	end

	-- Serialize script source
	if instance:IsA("LuaSourceContainer") then
		local success, source = pcall(function()
			return (instance :: any).Source
		end)
		if success and source then
			data.source = source
		end
	end

	-- Serialize properties based on class type
	local properties = {}
	local hasProperties = false

	-- Try each property group
	for baseClass, propList in pairs(SERIALIZABLE_PROPERTIES) do
		if instance:IsA(baseClass) then
			for _, propName in ipairs(propList) do
				local success, value = pcall(function()
					return (instance :: any)[propName]
				end)
				if success and value ~= nil then
					-- Skip ObjectReferences (like PrimaryPart) - they can't be serialized
					if typeof(value) ~= "Instance" then
						local serialized = PropertySerializer.serializePropertyValue(propName, instance, value)
						if serialized ~= nil then
							properties[propName] = serialized
							hasProperties = true
						end
					end
				end
			end
		end
	end

	-- Serialize Model-specific method-based properties
	-- These can't go in SERIALIZABLE_PROPERTIES because they require method calls, not instance[propName]
	if instance:IsA("Model") then
		local model = instance :: Model
		local scaleOk, scale = pcall(function()
			return model:GetScale()
		end)
		if scaleOk and scale then
			properties._ModelScale = scale
			hasProperties = true
		end
		local pivotOk, pivot = pcall(function()
			return model:GetPivot()
		end)
		if pivotOk and pivot then
			properties._ModelPivot = { pivot.Position.X, pivot.Position.Y, pivot.Position.Z }
			hasProperties = true
		end
	end

	if hasProperties then
		data.properties = properties
	end

	return data
end

-- Recursively serialize an instance and all its descendants
local function serializeTree(instance: Instance): {
	className: string,
	name: string,
	uniqueId: string?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?,
	source: string?,
	children: { any }?,
}
	local data = serializeInstance(instance)

	-- Serialize children recursively
	local children = instance:GetChildren()
	if #children > 0 then
		local serializedChildren = {}
		for _, child in ipairs(children) do
			table.insert(serializedChildren, serializeTree(child))
		end
		(data :: any).children = serializedChildren
	end

	return data :: any
end

-- Main handler
return function(
	self,
	params: { uniqueId: string }
): {
	status: string,
	uniqueId: string?,
	className: string?,
	path: string?,
	parentPath: string?,
	parentUniqueId: string?,
	data: string?, -- JSON-encoded serialized tree
	source: string?, -- Script source (separate for convenience)
	error: string?,
}
	Log.info("[StudioActions.serialize] BEGIN - Serializing uniqueId:", params.uniqueId)

	local instance = self.tree:getInstance(params.uniqueId)
	if not instance then
		Log.warn("[StudioActions.serialize] Instance not found:", params.uniqueId)
		return {
			status = "failed",
			error = string.format("Instance not found: %s", params.uniqueId),
		}
	end

	local path = helpers.getInstancePath(instance)
	local parentPath = nil :: string?
	local parentUniqueId = nil :: string?

	if instance.Parent then
		parentPath = helpers.getInstancePath(instance.Parent)
		parentUniqueId = UniqueIdHelpers.getUniqueId(instance.Parent)
	end

	-- Serialize the entire tree
	local serialized = serializeTree(instance)

	-- Encode as JSON
	local HttpService = game:GetService("HttpService")
	local success, jsonData = pcall(function()
		return HttpService:JSONEncode(serialized)
	end)

	if not success then
		Log.error("[StudioActions.serialize] Failed to encode JSON:", jsonData)
		return {
			status = "failed",
			error = "Failed to serialize instance data",
		}
	end

	-- Extract source for scripts (convenience field)
	local source = nil :: string?
	if instance:IsA("LuaSourceContainer") then
		pcall(function()
			source = (instance :: any).Source
		end)
	end

	Log.info(
		string.format(
			"[StudioActions.serialize] SUCCESS - Serialized %s (%s), data size: %d bytes",
			path,
			instance.ClassName,
			#jsonData
		)
	)

	return {
		status = "completed",
		uniqueId = params.uniqueId,
		className = instance.ClassName,
		path = path,
		parentPath = parentPath,
		parentUniqueId = parentUniqueId,
		data = jsonData,
		source = source,
	}
end
