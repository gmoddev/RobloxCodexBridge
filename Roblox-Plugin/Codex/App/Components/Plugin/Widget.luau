local plugin = script:FindFirstAncestorWhichIsA("Plugin")

local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components
local Util = Components.Util

local Fusion = require(Codex.Packages.Fusion)

local stripProps = require(Util.stripProps)
local isState = require(Util.isState)
local default = require(Util.default)

local Hydrate = Fusion.Hydrate
local peek = Fusion.peek
local Observer = Fusion.Observer

local COMPONENT_ONLY_PROPS = {
	"Id",
	"InitialDockTo",
	"InitialEnabled",
	"OverrideEnabled",
	"FloatingSize",
	"MinimumSize",
	"Closed",
}

type WidgetProps = {
	Id: string?,
	InitialDockTo: Enum.InitialDockState?,
	InitialEnabled: boolean?,
	OverrideEnabled: boolean?,
	FloatingSize: Vector2?,
	MinimumSize: Vector2,
	Closed: (() -> ())?,
	[any]: any,
}

return function(props: WidgetProps): DockWidgetPluginGui
	local floatingSize = props.FloatingSize or props.MinimumSize

	-- Extract boolean value from OverrideEnabled (handle state objects)
	local overrideEnabled = props.OverrideEnabled
	if isState(overrideEnabled) then
		overrideEnabled = peek(overrideEnabled)
	end

	local widget = plugin:CreateDockWidgetPluginGui(
		props.Id or peek(props.Name),
		DockWidgetPluginGuiInfo.new(
			props.InitialDockTo or Enum.InitialDockState.Float,
			default(props.InitialEnabled, true),
			default(overrideEnabled, false),
			floatingSize.X,
			floatingSize.Y,
			props.MinimumSize.X,
			props.MinimumSize.Y
		)
	)

	if isState(props.Enabled) then
		props.Enabled:set(widget.Enabled)
	end

	-- Reactively update widget.Enabled when OverrideEnabled state changes
	if isState(props.OverrideEnabled) then
		Observer(props.OverrideEnabled):onChange(function()
			widget.Enabled = peek(props.OverrideEnabled)
		end)
		-- Set initial value
		widget.Enabled = peek(props.OverrideEnabled)
	end

	if props.Closed then
		widget:BindToClose(props.Closed)
	end

	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	props.Title = props.Name

	return Hydrate(widget)(stripProps(props, COMPONENT_ONLY_PROPS))
end
