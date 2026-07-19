local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App

local Fusion = require(Codex.Packages.Fusion)
local Theme = require(App.Theme)

local New = Fusion.New
local Computed = Fusion.Computed
local Children = Fusion.Children

return function(props)
	return New "Frame" {
		Name = "StatusButton",
		BackgroundColor3 = Color3.fromRGB(68, 68, 68),
		Size = props.Size or UDim2.new(0, 90, 0, Theme.CompSizeY.Large),
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			-- Rounded corners
			New "UICorner" {
				CornerRadius = UDim.new(0, 6),
			},

			-- Status text
			New "TextLabel" {
				Name = "StatusText",
				Position = UDim2.fromScale(0, 0.5),
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundTransparency = 1,
				Text = "Status",
				TextColor3 = Color3.fromRGB(165, 165, 165),
				TextSize = Theme.TextSize.Large,
				Size = UDim2.new(0.6, 0, 1, 0),
				FontFace = Theme.Fonts.Regular,
				TextXAlignment = Enum.TextXAlignment.Left,

				[Children] = {
					-- Add padding to the text
					New "UIPadding" {
						PaddingLeft = UDim.new(0, 10),
					},
				},
			},

			-- Status indicator dot
			New "Frame" {
				Name = "StatusDot",
				Position = UDim2.new(1, -19, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = Computed(function(use)
					local isConnected = props.IsConnected
					if type(isConnected) == "table" and isConnected.get then
						isConnected = use(props.IsConnected)
					end

					return isConnected and Color3.fromRGB(62, 148, 65) -- Green for connected
						or Color3.fromRGB(116, 38, 38) -- Red for disconnected
				end),
				Size = UDim2.fromOffset(8, 8),
				BorderSizePixel = 0,

				[Children] = {
					New "UICorner" {
						CornerRadius = UDim.new(0.5, 0),
					},
				},
			},
		},
	}
end
