local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components

local Fusion = require(Codex.Packages.Fusion)

local Theme = require(App.Theme)

local Container = require(Components.Container)
local Text = require(Components.Text)
local Border = require(Components.Border)

local New = Fusion.New
local Computed = Fusion.Computed
local Children = Fusion.Children

type Props = {
	-- Progress value between 0 and 1
	Progress: Fusion.CanBeState<number>?,
	-- Text to display above the progress bar
	Text: Fusion.CanBeState<string>?,
	-- Optional size override
	Size: UDim2?,
}

return function(props: Props): Frame
	local progress = props.Progress or 0
	local displayText = props.Text or ""

	return Container {
		Size = props.Size or UDim2.new(1, 0, 0, 60),
		BackgroundTransparency = 1, -- Make outer container transparent (only show inner progress bar)
		AutomaticSize = Enum.AutomaticSize.None,

		[Children] = {
			-- No border on outer container (only on progress bar itself)

			-- Layout
			New("UIListLayout") {
				Padding = UDim.new(0, 8),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},

			-- Status text (hide when empty)
			Text {
				Text = displayText,
				Font = Theme.Fonts.Bold,
				Size = Computed(function(use)
					-- Use reactive subscription for state updates
					local text = typeof(displayText) == "table" and use(displayText) or displayText
					if text and text ~= "" then
						return UDim2.new(1, -16, 0, 20)
					else
						return UDim2.new(1, -16, 0, 0)
					end
				end),
				TextXAlignment = Enum.TextXAlignment.Center,
			},

			-- Progress bar container
			Container {
				Size = UDim2.new(1, -16, 0, 12),
				BackgroundColor3 = Theme.Colors.ActiveBackground,

				[Children] = {
					Border {},

					-- Progress bar fill
					New("Frame") {
						Size = Computed(function(use)
							-- Use reactive subscription for state updates (not peek!)
							local value = typeof(progress) == "table" and use(progress) or progress
							local clamped = math.clamp(value, 0, 1)
							return UDim2.new(clamped, 0, 1, 0)
						end),
						BackgroundColor3 = Theme.Colors.Brand,
						BorderSizePixel = 0,
					},
				},
			},
		},
	}
end
