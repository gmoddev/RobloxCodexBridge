local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components

local Fusion = require(Codex.Packages.Fusion)
local Log = require(Codex.Log)

local Theme = require(App.Theme)

local TextButton = require(Components.TextButton)
local Spinner = require(Components.Spinner)
local List = require(Components.List)
local Box = require(Components.Box)
local Text = require(Components.Text)

local Children = Fusion.Children
local New = Fusion.New

type Props = {
	App: { [string]: any },
}

return function(props: Props): { Instance }
	return {
		List {
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
		},
		Box {
			Size = UDim2.new(1, 0, 0, Theme.CompSizeY.Large * 3),
			[Children] = {
				New("Frame") {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					[Children] = {
						New("UIPadding") {
							PaddingTop = UDim.new(0, Theme.Padding * 2),
							PaddingLeft = UDim.new(0, Theme.Padding),
							PaddingRight = UDim.new(0, Theme.Padding),
						},
						List {
							HorizontalAlignment = Enum.HorizontalAlignment.Center,
							VerticalAlignment = Enum.VerticalAlignment.Top,
							Padding = UDim.new(0, 12),
						},
						Spinner {
							LayoutOrder = 1,
						},
						Text {
							Text = "Connecting to your project...",
							Color = Theme.Colors.TextDimmed,
							TextSize = Theme.TextSize.Small,
							TextXAlignment = Enum.TextXAlignment.Center,
							TextWrapped = true,
							Size = UDim2.new(1, -40, 0, 0),
							AutomaticSize = Enum.AutomaticSize.Y,
							LayoutOrder = 2,
						},
					},
				},
			},
		},
		TextButton {
			Text = "Cancel",
			Activated = function()
				Log.info("[Connecting] CANCEL BUTTON CLICKED")
				props.App:disconnect(true)
				props.App:home()
				Log.info("[Connecting] Cancel button handler finished")
			end,
		},
	}
end
