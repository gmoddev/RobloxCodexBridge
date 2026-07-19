local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components

local Fusion = require(Codex.Packages.Fusion)
local LogConfig = require(Codex.LogConfig)

local Theme = require(App.Theme)

local Text = require(Components.Text)
local TextButton = require(Components.TextButton)
local List = require(Components.List)
local StatusButton = require(Components.StatusButton)

local Children = Fusion.Children
local New = Fusion.New
local Value = Fusion.Value
local Computed = Fusion.Computed

type Props = {
	App: { [string]: any },
	Host: string,
	Port: number,
}

return function(props: Props): { Instance }
	local loggingEnabled = Value(LogConfig.getLogging()) -- Track current logging state

	local headerActions = New "Frame" {
		Name = "HeaderActions",
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		[Children] = {
			List {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
			},

			TextButton {
				Solid = true,
				LayoutOrder = 2,
				Text = "Connect",
				BackgroundColor3 = Color3.fromRGB(62, 148, 65), -- Green connect button
				Activated = function()
					props.App:connect()
				end,
			},
			StatusButton {
				LayoutOrder = 3,
				IsConnected = props.App.isConnectedState,
			},
		},
	}

	local pageContent = {
		List {},
		Text {
			Text = "Open a project in the browser then press Connect",
			TextSize = Theme.TextSize.Medium,
			Color = Theme.Colors.TextDimmed,
			TextWrapped = true,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 1,
		},

		-- Logging toggle button at the bottom
		New "Frame" {
			Name = "LoggingToggleContainer",
			Size = UDim2.new(1, 0, 0, 30), -- Small height container
			BackgroundTransparency = 1,
			LayoutOrder = 999, -- Ensure it's at the bottom
			[Children] = {
				TextButton {
					Text = Computed(function(use)
						return use(loggingEnabled) and "Logs On" or "Logs Off"
					end),
					Size = UDim2.fromOffset(65, 20), -- Very small height as requested
					Position = UDim2.new(1, -65, 0.5, -10), -- Aligned to right edge
					AnchorPoint = Vector2.new(0, 0.5), -- Left anchor, vertically centered
					TextSize = 12, -- Smaller text size
					BackgroundTransparency = 1, -- No background color
					TextColor3 = Computed(function(use)
						return use(loggingEnabled) and Color3.fromRGB(180, 50, 50) or Color3.fromRGB(165, 165, 165) -- Red when on, gray when off
					end),
					Activated = function()
						local newState = not LogConfig.getLogging()
						LogConfig.setLogging(newState)
						loggingEnabled:set(newState)
					end,
				},
			},
		},
	}

	return { headerActions, unpack(pageContent) }
end
