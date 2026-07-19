local Codex = script:FindFirstAncestor("Codex")

local Fusion = require(Codex.Packages.Fusion)

local New = Fusion.New
local Hydrate = Fusion.Hydrate

type Props = {
	[any]: any,
}

return function(props: Props): ImageLabel
	return Hydrate(New("ImageLabel") {
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
	})(props)
end
