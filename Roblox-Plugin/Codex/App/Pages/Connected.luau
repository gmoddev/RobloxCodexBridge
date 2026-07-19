local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App
local Components = App.Components

local Fusion = require(Codex.Packages.Fusion)
local Theme = require(App.Theme)
local LogConfig = require(Codex.LogConfig)

local TextButton = require(Components.TextButton)
local Padding = require(Components.Padding)
local Text = require(Components.Text)
local List = require(Components.List)
local Box = require(Components.Box)
local StatusButton = require(Components.StatusButton)

local Value = Fusion.Value
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children
local Cleanup = Fusion.Cleanup
local peek = Fusion.peek
local New = Fusion.New

type Props = {
	App: { [string]: any },
	Project: any,
}

return function(props: Props): { Instance }
	local syncedText = Value("just now")
	local loggingEnabled = Value(LogConfig.getLogging()) -- Track current logging state

	local function updateSyncedText()
		return task.spawn(function()
			while true do
				local elapsed = os.time() - peek(props.App.lastSync)
				local interval = 1
				local text

				if elapsed < 1 then
					text = "just now"
				elseif elapsed < 60 then
					text = math.floor(elapsed) .. "s ago:"
				elseif elapsed < 3600 then
					interval = 60
					text = elapsed // interval .. "m ago:"
				elseif elapsed < 86400 then
					interval = 3600
					text = elapsed // interval .. "h ago:"
				else
					interval = 86400
					text = elapsed // interval .. "d ago:"
				end

				syncedText:set(text)
				task.wait(interval)
			end
		end)
	end

	local thread = updateSyncedText()
	local disconnectObserver = Observer(props.App.lastSync):onChange(function()
		task.cancel(thread)
		thread = updateSyncedText()
	end)

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
				Text = "Disconnect",
				LayoutOrder = 2,
				Solid = true,
				BackgroundColor3 = Color3.fromRGB(68, 68, 68), -- Match StatusButton background
				TextColor3 = Color3.fromRGB(165, 165, 165), -- Match StatusButton text color
				Activated = function()
					props.App:disconnect()
					props.App:home()
				end,
			},
			StatusButton {
				LayoutOrder = 3,
				IsConnected = props.App.isConnectedState,
			},
		},
		[Cleanup] = function()
			disconnectObserver()
			task.cancel(thread)
		end,
	}

	local pageContent = {
		List {},
		Box {
			Size = UDim2.new(1, 0, 0, Theme.CompSizeY.Large * 1.5),
			[Children] = {
				Padding {},
				-- Line 1: Project label
				Text {
					Position = UDim2.fromScale(0, 0),
					Size = UDim2.fromScale(0.25, 0.45),
					Text = "Project:",
					TextSize = Theme.TextSize.Medium,
					Color = Theme.Colors.TextDimmed,
					Font = Theme.Fonts.Mono,
					Scaled = true,
				},
				-- Line 1: Project name
				Text {
					Position = UDim2.fromScale(0.25, 0),
					Size = UDim2.fromScale(0.25, 0.45),
					Text = Computed(function(use)
						local project = use(props.Project)
						return project and project.name or "" -- Return project name or empty string if nil
					end),
					Font = Theme.Fonts.Bold,
					Scaled = true,
				},

				-- Line 2: Prompts label
				Text {
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.fromScale(0.25, 0.45),
					Text = "Prompts:",
					TextSize = Theme.TextSize.Medium,
					Color = Theme.Colors.TextDimmed,
					Font = Theme.Fonts.Mono,
					Scaled = true,
				},
				-- Line 2: Prompts count
				Text {
					Position = UDim2.fromScale(0.25, 0.5),
					Size = UDim2.fromScale(0.25, 0.45),
					Text = Computed(function(use)
						local project = use(props.Project)
						local count = project and project.promptCount or 0
						return tostring(count)
					end),
					Font = Theme.Fonts.Bold,
					Scaled = true,
				},

				-- Right Column: Status
				Text {
					Position = UDim2.fromScale(0.5, 0),
					Size = UDim2.fromScale(0.5, 1),
					Text = Computed(function(use)
						local lastSyncKind = use(props.App.lastSyncKind)
						local lastSyncedFile = use(props.App.lastSyncedFile)
						if lastSyncedFile == "Unknown" then
							return "Send a web message..."
						end
						local prefix = "Studio sync "
						if lastSyncKind == "Server" then
							prefix = "Web sync "
						end
						return prefix .. use(syncedText) .. "\n" .. lastSyncedFile
					end),
					RichText = false,
					Color = Theme.Colors.TextDimmed,
					TextSize = Theme.TextSize.Medium,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextYAlignment = Enum.TextYAlignment.Center,
					LineHeight = 1.2,
					Scaled = true,
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
