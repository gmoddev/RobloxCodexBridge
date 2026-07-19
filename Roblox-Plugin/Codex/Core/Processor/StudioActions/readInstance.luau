--!strict
-- readInstance: Query instance metadata (class, attributes, properties)

local Codex = script:FindFirstAncestor("Codex")
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: { uniqueId: string }
): {
	status: string,
	robloxClass: string?,
	uniqueId: string?,
	parentId: string?,
	path: string?,
	attributes: { [string]: any }?,
	properties: { [string]: any }?,
	error: string?,
}
	local instance = self.tree:getInstance(params.uniqueId)
	if not instance then
		return {
			status = "failed",
			error = string.format("Instance not found: %s", params.uniqueId),
		}
	end

	-- Get attributes
	local attributes = {}
	for attr, value in pairs(instance:GetAttributes()) do
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(attr) then -- Exclude internal attributes
			attributes[attr] = value
		end
	end

	-- Get common properties (if applicable)
	local properties = {}
	pcall(function()
		if instance:IsA("BasePart") then
			properties.Color = { instance.Color.R * 255, instance.Color.G * 255, instance.Color.B * 255 }
			properties.Size = { instance.Size.X, instance.Size.Y, instance.Size.Z }
			properties.Anchored = instance.Anchored
			properties.CFrame =
				{ Position = { instance.CFrame.Position.X, instance.CFrame.Position.Y, instance.CFrame.Position.Z } }
		elseif instance:IsA("Model") then
			local model = instance :: Model
			properties.Scale = model:GetScale()
			local extents = model:GetExtentsSize()
			properties.ExtentsSize = { extents.X, extents.Y, extents.Z }
			local pivot = model:GetPivot()
			properties.Pivot = {
				Position = { pivot.Position.X, pivot.Position.Y, pivot.Position.Z }
			}
			if model.PrimaryPart then
				local ppUniqueId = UniqueIdHelpers.getUniqueId(model.PrimaryPart)
				properties.PrimaryPart = {
					Name = model.PrimaryPart.Name,
					UniqueId = ppUniqueId,
				}
			end
		elseif instance:IsA("GuiObject") then
			local guiObj = instance :: GuiObject
			properties.Position = { X = { guiObj.Position.X.Scale, guiObj.Position.X.Offset }, Y = { guiObj.Position.Y.Scale, guiObj.Position.Y.Offset } }
			properties.Size = { X = { guiObj.Size.X.Scale, guiObj.Size.X.Offset }, Y = { guiObj.Size.Y.Scale, guiObj.Size.Y.Offset } }
			properties.AnchorPoint = { guiObj.AnchorPoint.X, guiObj.AnchorPoint.Y }
			properties.BackgroundColor3 = { guiObj.BackgroundColor3.R * 255, guiObj.BackgroundColor3.G * 255, guiObj.BackgroundColor3.B * 255 }
			properties.BackgroundTransparency = guiObj.BackgroundTransparency
			properties.Visible = guiObj.Visible
			properties.ZIndex = guiObj.ZIndex

			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				local img = instance :: ImageLabel
				properties.Image = img.Image
				properties.ImageColor3 = { img.ImageColor3.R * 255, img.ImageColor3.G * 255, img.ImageColor3.B * 255 }
				properties.ImageTransparency = img.ImageTransparency
				properties.ScaleType = img.ScaleType.Name
				properties.TileSize = { X = { img.TileSize.X.Scale, img.TileSize.X.Offset }, Y = { img.TileSize.Y.Scale, img.TileSize.Y.Offset } }
			elseif instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				local txt = instance :: TextLabel
				properties.Text = txt.Text
				properties.TextColor3 = { txt.TextColor3.R * 255, txt.TextColor3.G * 255, txt.TextColor3.B * 255 }
				properties.TextSize = txt.TextSize
				properties.Font = txt.Font.Name
				properties.TextScaled = txt.TextScaled
				properties.TextWrapped = txt.TextWrapped
			end
		elseif instance:IsA("ScreenGui") then
			local sg = instance :: ScreenGui
			properties.DisplayOrder = sg.DisplayOrder
			properties.Enabled = sg.Enabled
			properties.IgnoreGuiInset = sg.IgnoreGuiInset
			properties.ResetOnSpawn = sg.ResetOnSpawn
		end
	end)

	local parentId = instance.Parent and UniqueIdHelpers.getUniqueId(instance.Parent) or nil

	return {
		status = "completed",
		robloxClass = instance.ClassName,
		uniqueId = params.uniqueId,
		parentId = parentId,
		path = helpers.getInstancePath(instance),
		attributes = next(attributes) and attributes or nil,
		properties = next(properties) and properties or nil,
	}
end
