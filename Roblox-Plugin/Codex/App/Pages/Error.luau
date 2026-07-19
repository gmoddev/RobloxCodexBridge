local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components
local Util = Components.Util

local Fusion = require(Codex.Packages.Fusion)
local LogConfig = require(Codex.LogConfig)

local Theme = require(App.Theme)
local getTextSize = require(Util.getTextSize)

local TextButton = require(Components.TextButton)
local ScrollingContainer = require(Components.ScrollingContainer)
local Padding = require(Components.Padding)
local Text = require(Components.Text)
local List = require(Components.List)
local Box = require(Components.Box)

local Value = Fusion.Value
local Computed = Fusion.Computed
local OnChange = Fusion.OnChange
local Children = Fusion.Children
local New = Fusion.New

type Props = {
	App: { [string]: any },
	Message: string,
}

return function(props: Props): { Instance }
	local absoluteSize = Value(Vector2.zero)
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
				Padding = UDim.new(0, Theme.Padding),
			},

			TextButton {
				Text = "Proceed",
				LayoutOrder = 2,
				Solid = true,
				BackgroundColor3 = Color3.fromRGB(62, 148, 65),
				Activated = function()
					props.App:home()
				end,
			},
		},
	}

	local pageContent = {
		List {},
		Box {
			AutomaticSize = Enum.AutomaticSize.None,
			Size = Computed(function(use)
				local currentAbsoluteSize = use(absoluteSize)
				local rootSize = use(props.App.rootSize)

				local textSize = getTextSize(
					props.Message,
					Theme.TextSize.Medium,
					Theme.Fonts.Enums.Mono,
					Vector2.new(currentAbsoluteSize.X - Theme.Padding * 2 - 2, math.huge)
				)
				local height = math.min(textSize.Y + Theme.Padding * 2, rootSize.Y - 120)

				return UDim2.new(1, 0, 0, height)
			end),

			[OnChange "AbsoluteSize"] = function(newSize)
				absoluteSize:set(newSize)
			end,

			[Children] = {
				ScrollingContainer {
					Size = UDim2.new(1, -2, 1, 0),
					ScrollBar = true,
					[Children] = {
						Padding {},
						Text {
							Text = props.Message,
							RichText = true,
							TextWrapped = true,
							Font = Theme.Fonts.Mono,
							TextSize = Theme.TextSize.Medium,
						},
					},
				},
			},
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
