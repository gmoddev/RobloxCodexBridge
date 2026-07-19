--!strict
-- readGuiTree: Read a bounded GUI subtree for Codex inspection.

local Codex = script:FindFirstAncestor("Codex")

local Log = require(Codex.Log)
local PropertySerializer = require(Codex.Util.PropertySerializer)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local Helpers = require(script.Parent.helpers)

local DEFAULT_ROOT_UNIQUE_ID = "sg1"
local DEFAULT_MAX_DEPTH = 6
local DEFAULT_MAX_NODES = 500
local HARD_MAX_DEPTH = 20
local HARD_MAX_NODES = 1000
local YIELD_INTERVAL_SECONDS = 0.010

local function Coalesce(Value: any, Fallback: any): any
	if Value ~= nil then
		return Value
	end
	return Fallback
end

local function SerializeProperty(InstanceObject: Instance, PropertyName: string): any?
	local Success, Value = pcall(function()
		return (InstanceObject :: any)[PropertyName]
	end)

	if not Success or Value == nil then
		return nil
	end

	return PropertySerializer.serializePropertyValue(PropertyName, InstanceObject, Value)
end

local function AddProperty(Properties: { [string]: any }, InstanceObject: Instance, PropertyName: string)
	local Serialized = SerializeProperty(InstanceObject, PropertyName)
	if Serialized ~= nil then
		Properties[PropertyName] = Serialized
	end
end

local function AddRawProperty(Properties: { [string]: any }, InstanceObject: Instance, PropertyName: string)
	local Success, Value = pcall(function()
		return (InstanceObject :: any)[PropertyName]
	end)

	if Success and Value ~= nil then
		if typeof(Value) == "EnumItem" then
			Value = Value.Name
		end
		Properties[PropertyName] = Value
	end
end

local function ReadProperties(
	InstanceObject: Instance,
	IncludeAbsolute: boolean,
	IncludeText: boolean,
	IncludeImages: boolean,
	IncludeLayout: boolean
): { [string]: any }?
	local Properties = {}

	if InstanceObject:IsA("ScreenGui") then
		AddRawProperty(Properties, InstanceObject, "DisplayOrder")
		AddRawProperty(Properties, InstanceObject, "Enabled")
		AddRawProperty(Properties, InstanceObject, "IgnoreGuiInset")
		AddRawProperty(Properties, InstanceObject, "ResetOnSpawn")
		AddRawProperty(Properties, InstanceObject, "ZIndexBehavior")
	end

	if InstanceObject:IsA("GuiObject") then
		local GuiObject = InstanceObject :: GuiObject
		AddProperty(Properties, GuiObject, "Position")
		AddProperty(Properties, GuiObject, "Size")
		AddProperty(Properties, GuiObject, "AnchorPoint")
		AddProperty(Properties, GuiObject, "BackgroundColor3")
		AddRawProperty(Properties, GuiObject, "BackgroundTransparency")
		AddRawProperty(Properties, GuiObject, "BorderSizePixel")
		AddRawProperty(Properties, GuiObject, "Visible")
		AddRawProperty(Properties, GuiObject, "ZIndex")
		AddRawProperty(Properties, GuiObject, "LayoutOrder")
		AddRawProperty(Properties, GuiObject, "Rotation")
		AddRawProperty(Properties, GuiObject, "ClipsDescendants")
		AddRawProperty(Properties, GuiObject, "AutomaticSize")

		if IncludeAbsolute then
			Properties.AbsolutePosition = { GuiObject.AbsolutePosition.X, GuiObject.AbsolutePosition.Y }
			Properties.AbsoluteSize = { GuiObject.AbsoluteSize.X, GuiObject.AbsoluteSize.Y }
		end
	end

	if IncludeImages and (InstanceObject:IsA("ImageLabel") or InstanceObject:IsA("ImageButton")) then
		AddRawProperty(Properties, InstanceObject, "Image")
		AddProperty(Properties, InstanceObject, "ImageColor3")
		AddRawProperty(Properties, InstanceObject, "ImageTransparency")
		AddRawProperty(Properties, InstanceObject, "ScaleType")
		AddProperty(Properties, InstanceObject, "TileSize")
		AddProperty(Properties, InstanceObject, "SliceCenter")
		AddProperty(Properties, InstanceObject, "ImageRectOffset")
		AddProperty(Properties, InstanceObject, "ImageRectSize")
	end

	if IncludeText and (InstanceObject:IsA("TextLabel") or InstanceObject:IsA("TextButton") or InstanceObject:IsA("TextBox")) then
		AddRawProperty(Properties, InstanceObject, "Text")
		AddProperty(Properties, InstanceObject, "TextColor3")
		AddRawProperty(Properties, InstanceObject, "TextSize")
		AddRawProperty(Properties, InstanceObject, "Font")
		AddRawProperty(Properties, InstanceObject, "TextScaled")
		AddRawProperty(Properties, InstanceObject, "TextWrapped")
		AddRawProperty(Properties, InstanceObject, "TextXAlignment")
		AddRawProperty(Properties, InstanceObject, "TextYAlignment")
		AddRawProperty(Properties, InstanceObject, "TextTransparency")
		AddProperty(Properties, InstanceObject, "TextStrokeColor3")
		AddRawProperty(Properties, InstanceObject, "TextStrokeTransparency")
		AddRawProperty(Properties, InstanceObject, "RichText")

		if InstanceObject:IsA("TextBox") then
			AddRawProperty(Properties, InstanceObject, "PlaceholderText")
			AddRawProperty(Properties, InstanceObject, "ClearTextOnFocus")
			AddRawProperty(Properties, InstanceObject, "MultiLine")
		end
	end

	if IncludeLayout then
		if InstanceObject:IsA("UIListLayout") then
			AddRawProperty(Properties, InstanceObject, "FillDirection")
			AddRawProperty(Properties, InstanceObject, "HorizontalAlignment")
			AddRawProperty(Properties, InstanceObject, "VerticalAlignment")
			AddProperty(Properties, InstanceObject, "Padding")
			AddRawProperty(Properties, InstanceObject, "SortOrder")
			AddRawProperty(Properties, InstanceObject, "HorizontalFlex")
			AddRawProperty(Properties, InstanceObject, "VerticalFlex")
			AddRawProperty(Properties, InstanceObject, "Wraps")
		elseif InstanceObject:IsA("UIGridLayout") then
			AddProperty(Properties, InstanceObject, "CellSize")
			AddProperty(Properties, InstanceObject, "CellPadding")
			AddRawProperty(Properties, InstanceObject, "FillDirection")
			AddRawProperty(Properties, InstanceObject, "HorizontalAlignment")
			AddRawProperty(Properties, InstanceObject, "VerticalAlignment")
			AddRawProperty(Properties, InstanceObject, "SortOrder")
			AddRawProperty(Properties, InstanceObject, "FillDirectionMaxCells")
		elseif InstanceObject:IsA("UIPadding") then
			AddProperty(Properties, InstanceObject, "PaddingTop")
			AddProperty(Properties, InstanceObject, "PaddingBottom")
			AddProperty(Properties, InstanceObject, "PaddingLeft")
			AddProperty(Properties, InstanceObject, "PaddingRight")
		elseif InstanceObject:IsA("UICorner") then
			AddProperty(Properties, InstanceObject, "CornerRadius")
		elseif InstanceObject:IsA("UIStroke") then
			AddProperty(Properties, InstanceObject, "Color")
			AddRawProperty(Properties, InstanceObject, "Thickness")
			AddRawProperty(Properties, InstanceObject, "Transparency")
			AddRawProperty(Properties, InstanceObject, "ApplyStrokeMode")
			AddRawProperty(Properties, InstanceObject, "LineJoinMode")
		elseif InstanceObject:IsA("UIScale") then
			AddRawProperty(Properties, InstanceObject, "Scale")
		elseif InstanceObject:IsA("UIAspectRatioConstraint") then
			AddRawProperty(Properties, InstanceObject, "AspectRatio")
			AddRawProperty(Properties, InstanceObject, "AspectType")
			AddRawProperty(Properties, InstanceObject, "DominantAxis")
		elseif InstanceObject:IsA("UISizeConstraint") then
			AddProperty(Properties, InstanceObject, "MinSize")
			AddProperty(Properties, InstanceObject, "MaxSize")
		elseif InstanceObject:IsA("UITextSizeConstraint") then
			AddRawProperty(Properties, InstanceObject, "MinTextSize")
			AddRawProperty(Properties, InstanceObject, "MaxTextSize")
		elseif InstanceObject:IsA("UIGradient") then
			AddProperty(Properties, InstanceObject, "Color")
			AddProperty(Properties, InstanceObject, "Offset")
			AddRawProperty(Properties, InstanceObject, "Rotation")
			AddProperty(Properties, InstanceObject, "Transparency")
		elseif InstanceObject:IsA("ScrollingFrame") then
			AddProperty(Properties, InstanceObject, "CanvasSize")
			AddProperty(Properties, InstanceObject, "CanvasPosition")
			AddRawProperty(Properties, InstanceObject, "ScrollBarThickness")
			AddProperty(Properties, InstanceObject, "ScrollBarImageColor3")
			AddRawProperty(Properties, InstanceObject, "ScrollingDirection")
			AddRawProperty(Properties, InstanceObject, "ScrollBarImageTransparency")
			AddRawProperty(Properties, InstanceObject, "ElasticBehavior")
		end
	end

	if next(Properties) then
		return Properties
	end

	return nil
end

return function(
	self,
	params: {
		rootUniqueId: string?,
		RootUniqueId: string?,
		maxDepth: number?,
		MaxDepth: number?,
		maxNodes: number?,
		MaxNodes: number?,
		includeAbsolute: boolean?,
		IncludeAbsolute: boolean?,
		includeText: boolean?,
		IncludeText: boolean?,
		includeImages: boolean?,
		IncludeImages: boolean?,
		includeLayout: boolean?,
		IncludeLayout: boolean?,
	}
): {
	status: string,
	Root: any?,
	NodeCount: number?,
	Truncated: boolean?,
	Warnings: { string }?,
	error: string?,
}
	local RootUniqueId = Coalesce(params.RootUniqueId, params.rootUniqueId) or DEFAULT_ROOT_UNIQUE_ID
	local MaxDepth = math.clamp(Coalesce(params.MaxDepth, params.maxDepth) or DEFAULT_MAX_DEPTH, 1, HARD_MAX_DEPTH)
	local MaxNodes = math.clamp(Coalesce(params.MaxNodes, params.maxNodes) or DEFAULT_MAX_NODES, 1, HARD_MAX_NODES)
	local IncludeAbsolute = Coalesce(params.IncludeAbsolute, params.includeAbsolute) == true
	local IncludeText = Coalesce(params.IncludeText, params.includeText)
	local IncludeImages = Coalesce(params.IncludeImages, params.includeImages)
	local IncludeLayout = Coalesce(params.IncludeLayout, params.includeLayout)

	if IncludeText == nil then
		IncludeText = true
	end
	if IncludeImages == nil then
		IncludeImages = true
	end
	if IncludeLayout == nil then
		IncludeLayout = true
	end

	local RootInstance = self.tree:getInstance(RootUniqueId)
	if not RootInstance and RootUniqueId == DEFAULT_ROOT_UNIQUE_ID then
		RootInstance = game:GetService("StarterGui")
		self.tree:insertInstance(RootInstance, DEFAULT_ROOT_UNIQUE_ID, {})
		UniqueIdHelpers.setUniqueId(RootInstance, DEFAULT_ROOT_UNIQUE_ID)
	end

	if not RootInstance then
		return {
			status = "failed",
			error = string.format("Instance not found: %s", RootUniqueId),
		}
	end

	local NodeCount = 0
	local Truncated = false
	local Warnings: { string } = {}
	local LastYieldTime = os.clock()

	local function MaybeYield()
		if os.clock() - LastYieldTime >= YIELD_INTERVAL_SECONDS then
			task.wait()
			LastYieldTime = os.clock()
		end
	end

	local function ReadNode(InstanceObject: Instance, Depth: number): any?
		if NodeCount >= MaxNodes then
			Truncated = true
			return nil
		end

		NodeCount += 1

		local UniqueId = UniqueIdHelpers.getUniqueId(InstanceObject)
		if not UniqueId then
			UniqueId = self.tree:getId(InstanceObject)
		end
		if not UniqueId then
			UniqueId = Helpers.generateUniqueId()
			UniqueIdHelpers.setUniqueId(InstanceObject, UniqueId)
			self.tree:insertInstance(InstanceObject, UniqueId, {})
			table.insert(Warnings, "Generated missing CodexUniqueID for " .. InstanceObject:GetFullName())
		end

		local Children = {}
		if Depth < MaxDepth then
			for _, Child in ipairs(InstanceObject:GetChildren()) do
				local ChildNode = ReadNode(Child, Depth + 1)
				if ChildNode then
					table.insert(Children, ChildNode)
				end
				if Truncated then
					break
				end
			end
		elseif #InstanceObject:GetChildren() > 0 then
			Truncated = true
		end

		MaybeYield()

		return {
			Name = InstanceObject.Name,
			ClassName = InstanceObject.ClassName,
			UniqueId = UniqueId,
			Path = Helpers.getInstancePath(InstanceObject),
			HasChildren = #InstanceObject:GetChildren() > 0,
			Properties = ReadProperties(InstanceObject, IncludeAbsolute, IncludeText, IncludeImages, IncludeLayout),
			Children = #Children > 0 and Children or nil,
		}
	end

	Log.info(
		string.format(
			"[StudioActions.readGuiTree] Reading root=%s maxDepth=%d maxNodes=%d",
			RootUniqueId,
			MaxDepth,
			MaxNodes
		)
	)

	local Root = ReadNode(RootInstance, 1)

	return {
		status = "completed",
		Root = Root,
		NodeCount = NodeCount,
		Truncated = Truncated,
		Warnings = #Warnings > 0 and Warnings or nil,
	}
end
