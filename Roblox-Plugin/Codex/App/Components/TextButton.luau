local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components
local Util = Components.Util

local Fusion = require(Codex.Packages.Fusion)

local Theme = require(App.Theme)
local stripProps = require(Util.stripProps)
local getTextSize = require(Util.getTextSize)

local Border = require(Components.Border)

local New = Fusion.New
local Value = Fusion.Value
local Hydrate = Fusion.Hydrate
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed
local Children = Fusion.Children

local COMPONENT_ONLY_PROPS = {
	"Activated",
	"Solid",
	"BackgroundColor3",
}

type Props = {
	Activated: (() -> ())?,
	Solid: any,
	BackgroundColor3: any,
	[any]: any,
}

return function(props: Props): TextButton
	local isHovered = Value(false)
	local isPressed = Value(false)

	local backgroundColor = Computed(function(use)
		if props.BackgroundColor3 then
			return use(props.BackgroundColor3)
		else
			return use(props.Solid) and use(Theme.Colors.Brand) or use(Theme.Colors.Background)
		end
	end)

	local size = props.Size
		or Computed(function(use)
			local text = use(props.Text)
			local size = getTextSize(text)

			return UDim2.fromOffset(size.X + 22, Theme.CompSizeY.Large)
		end)

	return Hydrate(New "TextButton" {
		Text = "Button",
		FontFace = Theme.Fonts.Regular,
		AutoButtonColor = false,
		TextSize = Theme.TextSize.Large,
		Size = size,
		BackgroundColor3 = backgroundColor,
		TextColor3 = Computed(function(use)
			if props.BackgroundColor3 then
				return Color3.new(1, 1, 1)
			else
				return use(props.Solid) and use(Theme.Colors.TextBranded) or use(Theme.Colors.Text)
			end
		end),

		[OnEvent "InputBegan"] = function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				isHovered:set(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				isPressed:set(true)
			end
		end,
		[OnEvent "InputEnded"] = function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				isHovered:set(false)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				isPressed:set(false)
			end
		end,
		[OnEvent "Activated"] = function()
			if props.Activated then
				props.Activated()
			end
		end,

		[Children] = {
			Border {
				Color = Computed(function(use)
					if props.BackgroundColor3 then
						return use(backgroundColor)
					else
						return use(props.Solid) and use(backgroundColor) or use(Theme.Colors.Border)
					end
				end),
				Transparency = Computed(function()
					return if props.BackgroundColor3 then 1 else 0
				end),
			},
		},
	})(stripProps(props, COMPONENT_ONLY_PROPS))
end
