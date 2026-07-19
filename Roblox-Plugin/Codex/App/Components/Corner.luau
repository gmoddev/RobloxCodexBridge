local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components
local Util = Components.Util

local Fusion = require(Codex.Packages.Fusion)

local Theme = require(App.Theme)
local stripProps = require(Util.stripProps)

local New = Fusion.New
local Hydrate = Fusion.Hydrate

local COMPONENT_ONLY_PROPS = {
	"Radius",
}

type Props = {
	Radius: number?,
	[any]: any,
}

return function(props: Props): UICorner
	return Hydrate(New "UICorner" {
		CornerRadius = UDim.new(0, props.Radius or Theme.CornerRadius),
	})(stripProps(props, COMPONENT_ONLY_PROPS))
end
