local Codex = script:FindFirstAncestor("Codex")
local App = script.Parent.Parent
local Components = App.Components
local Util = Components.Util

local Fusion = require(Codex.Packages.Fusion)
local Theme = require(App.Theme)
local getTextSize = require(Util.getTextSize)

local ScrollingContainer = require(Components.ScrollingContainer)
local TextButton = require(Components.TextButton)
local Padding = require(Components.Padding)
local Text = require(Components.Text)
local List = require(Components.List)
local Box = require(Components.Box)

local Value = Fusion.Value
local Computed = Fusion.Computed
local ForPairs = Fusion.ForPairs
local OnChange = Fusion.OnChange
local Children = Fusion.Children
local New = Fusion.New

type Props = {
	App: { [string]: any },
	Message: string,
	Options: { string },
	Signal: any,
}

return function(props: Props): { Instance }
	local absoluteSize = Value(Vector2.zero)

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
			ForPairs(props.Options, function(_, index, option)
				return index,
					TextButton {
						LayoutOrder = #props.Options - index + 1,
						Solid = index == 1,
						Text = option,
						BackgroundColor3 = if index == 1 then Color3.fromRGB(62, 148, 65) else nil,
						Activated = function()
							props.Signal:Fire(option)
						end,
					}
			end, Fusion.cleanup),
		},
	}

	local pageContent = {
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
							Text = tostring(props.Message or ""),
							RichText = true,
							TextWrapped = true,
							Font = Theme.Fonts.Mono,
							TextSize = Theme.TextSize.Medium,
						},
					},
				},
			},
		},
	}

	return { headerActions, unpack(pageContent) }
end
