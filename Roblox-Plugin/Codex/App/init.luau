local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local plugin = script:FindFirstAncestorWhichIsA("Plugin")

local Codex = script:FindFirstAncestor("Codex")
local Packages = Codex.Packages
local Helpers = Codex.Helpers

local Components = script.Components
local Widgets = script.Widgets
local Pages = script.Pages

-- Assuming the correct 'Packages' folder remains after manual deletion
local Fusion = require(Packages.Fusion)
local Signal = require(Packages.Signal)

local manifest = require(Codex.manifest)
local Config = require(Codex.Config)
local Util = require(Codex.Util)
local Core = require(Codex.Core)
local Log = require(Codex.Log)
local describeChanges = require(Helpers.describeChanges)

local Assets = require(script.Assets)
local Loader = require(script.Loader)
local Theme = require(script.Theme)

local Toolbar = require(Components.Plugin.Toolbar)
local ToolbarButton = require(Components.Plugin.ToolbarButton)
local Widget = require(Components.Plugin.Widget)
local Container = require(Components.Container)
local Padding = require(Components.Padding)
local Image = require(Components.Image)
local Text = require(Components.Text)
local List = require(Components.List)
local Prompt = require(Pages.Prompt)

local NotConnected = require(Pages.NotConnected)
local Connecting = require(Pages.Connecting)
local Connected = require(Pages.Connected)
local Unavailable = require(Pages.Unavailable)
local Error = require(Pages.Error)
local ConflictResolution = require(Pages.ConflictResolution)

local Settings = require(Widgets.Settings)
local Help = require(Widgets.Help)

local New = Fusion.New
local Value = Fusion.Value
local Spring = Fusion.Spring
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children
local cleanup = Fusion.cleanup
local peek = Fusion.peek

local App = {}
App.__index = App

function App.new()
	Loader.load()

	local self = setmetatable({}, App)

	self.core = nil
	self.lastUpdate = os.clock()
	self.onCanceled = Signal.new()

	self.host = "localhost"
	self.port = 4000

	self.lastSync = Value(os.time())
	self.lastSyncKind = Value("Unknown")
	self.lastSyncedFile = Value("Unknown")

	self.rootSize = Value(Vector2.new(300, 200))
	self.icon = Value(Assets.Codex.Logo)
	self.pages = Value({})

	self.settingsWidget = Value(nil)
	self.helpWidget = Value(nil)
	self.isConnectedState = Value(false)

	local isOpen = Value(false)

	local toolbarButton = ToolbarButton {
		Toolbar = Toolbar {
			Name = "Codex Labs",
		},
		Name = "Codex",
		ToolTip = "Open Codex UI",
		Image = self.icon,

		[OnEvent "Click"] = function()
			isOpen:set(not peek(isOpen))
		end,
	}

	Widget {
		Name = "Codex",
		MinimumSize = peek(self.rootSize),
		Enabled = isOpen,

		[OnChange "Enabled"] = function(isEnabled)
			isOpen:set(isEnabled)
		end,
		[OnChange "AbsoluteSize"] = function(size)
			self.rootSize:set(size)
		end,

		[Children] = self.pages,
	}

	plugin.Unloading:Connect(Observer(isOpen):onChange(function()
		toolbarButton:SetActive(peek(isOpen))
	end))

	toolbarButton:SetActive(peek(isOpen))

	if RunService:IsEdit() then
		-- Don't make HTTP calls on startup - user will connect manually
		-- This prevents warnings/errors before user interaction
		Log.info("[Codex] Plugin ready - waiting for user to connect")
		self:setPage(NotConnected {
			App = self,
			Host = self.host,
			Port = self.port,
		})
	else
		self:setPage(Unavailable())
	end

	local StudioService = game:GetService("StudioService")
	self.userId = tostring(StudioService:GetUserId())

	return self
end

function App:setIcon(icon: ("Ok" | "Warn" | "Error")?)
	if icon == "Ok" then
		self.icon:set(Assets.Codex.LogoOk)
	elseif icon == "Warn" then
		self.icon:set(Assets.Codex.LogoWarn)
	elseif icon == "Error" then
		self.icon:set(Assets.Codex.LogoError)
	else
		self.icon:set(Assets.Codex.Logo)
	end
end

function App:setPage(pageInput)
	local pages = peek(self.pages)

	for id, child in pages do
		if child._finished then
			pages[id] = nil
			continue
		end

		task.spawn(function()
			if child._destructor and child._value then
				child._destructor(child._value)
				child._finished = true
			end
		end)
	end

	local size = Value(UDim2.fromScale(1, 1))

	local processedPage = Computed(function()
		local headerActions = nil
		local contentElements = {}

		if type(pageInput) == "table" and #pageInput > 0 then
			if pageInput[1] and pageInput[1].Name == "HeaderActions" and pageInput[1].ClassName == "Frame" then
				headerActions = pageInput[1]
				for i = 2, #pageInput do
					table.insert(contentElements, pageInput[i])
				end
			else
				contentElements = pageInput
			end
		else
			if typeof(pageInput) == "Instance" then
				contentElements = { pageInput }
			else
				Log.warn("[Codex] Warning: Unexpected pageInput type in setPage:", typeof(pageInput))
			end
		end

		return New "Frame" {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = Spring(size, 10),
			BackgroundColor3 = Theme.Colors.Background,
			BorderSizePixel = 0,
			[Children] = {
				List {
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Spacing = 0,
				},
				Padding { Padding = Theme.WidgetPadding },

				Container {
					LayoutOrder = 1,
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					[Children] = {
						List {
							FillDirection = Enum.FillDirection.Horizontal,
							HorizontalAlignment = Enum.HorizontalAlignment.Left,
							HorizontalFlex = Enum.UIFlexAlignment.SpaceBetween,
							VerticalAlignment = Enum.VerticalAlignment.Center,
							Padding = UDim.new(0, 8),
						},
						Container {
							AutomaticSize = Enum.AutomaticSize.XY,
							BackgroundTransparency = 1,
							LayoutOrder = 1,
							[Children] = {
								List {
									FillDirection = Enum.FillDirection.Horizontal,
									VerticalAlignment = Enum.VerticalAlignment.Center,
									Padding = UDim.new(0, 8),
								},
								Image {
									Size = UDim2.fromOffset(35, 35),
									Image = Assets.Codex.Banner,
									LayoutOrder = 1,
								},
								Text {
									Text = `v{manifest.package.version}`,
									Color = Theme.Colors.TextDimmed,
									TextSize = Theme.TextSize.Small,
									LayoutOrder = 2,
								},
							},
						},
						Container {
							Name = "HeaderRightActions",
							AutomaticSize = Enum.AutomaticSize.XY,
							BackgroundTransparency = 1,
							LayoutOrder = 2,
							[Children] = if headerActions then { headerActions } else {},
						},
					},
				},

				New "Frame" {
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 0, Theme.Padding),
					BackgroundTransparency = 1,
				},

				Container {
					LayoutOrder = 3,
					Size = UDim2.fromScale(1, 1),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					[Children] = contentElements,
				},
			},
		}
	end, function(pageInstance)
		if not pageInstance then
			return
		end

		local TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		TweenService:Create(pageInstance, TWEEN_INFO, { BackgroundTransparency = 1 }):Play()

		for _, descendant in pageInstance:GetDescendants() do
			local properties = {}

			if descendant:IsA("GuiObject") then
				properties.BackgroundTransparency = 1

				if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
					properties.TextTransparency = 1
				elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
					properties.ImageTransparency = 1
					descendant.ImageColor3 = peek(Theme.Colors.Icon)
				end
			end

			if descendant:IsA("UIStroke") then
				properties.Transparency = 1
			end

			if next(properties) then
				TweenService:Create(descendant, TWEEN_INFO, properties):Play()
			end
		end

		pageInstance.ZIndex = 2

		size:set(UDim2.fromScale(1.2, 1))

		task.wait(0.2)
		cleanup(pageInstance)
	end)

	pages[Util.generateGUID()] = processedPage
	self.pages:set(pages)
end

function App:home()
	self.lastUpdate = os.clock()
	self.isConnectedState:set(false) -- Explicitly set to false for home/not connected

	self:setPage(NotConnected {
		App = self,
		Host = self.host,
		Port = self.port,
	})

	self:setIcon()
end

function App:settings()
	local widget = peek(self.settingsWidget)

	if widget then
		widget:Destroy()
		widget = nil
	else
		widget = Settings {
			Closed = function()
				peek(self.settingsWidget):Destroy()
				self.settingsWidget:set(nil)
			end,
		}
	end

	self.settingsWidget:set(widget)
end

function App:help()
	local widget = peek(self.helpWidget)

	if widget then
		widget:Destroy()
		widget = nil
	else
		widget = Help {
			Closed = function()
				peek(self.helpWidget):Destroy()
				self.helpWidget:set(nil)
			end,
		}
	end

	self.helpWidget:set(widget)
end

function App:connect()
	if not self.core then
		local SessionId = Config:get("CodexBridgeSessionId") or "local"
		if type(SessionId) ~= "string" or SessionId == "" then
			SessionId = "local"
		end
		plugin:SetSetting("PROJECT_ID", SessionId)
		Log.info("[CodexBridge] Starting local Studio session:", SessionId)
		self.core = Core.new(plugin, SessionId)
	end

	local project = Value({})
	local canceled = false
	local loading = true

	-- Initially, we are attempting to connect, but not yet connected.
	-- isConnectedState will be updated by onReady or onPrompt (if connection fails during prompt)
	-- or by run():catch if a more general error occurs.
	self.isConnectedState:set(false) -- Explicitly false during connection attempt

	task.spawn(function()
		task.wait(0.2)

		-- Check connection status reactively via isConnectedState for the Connecting page decision
		if not peek(self.isConnectedState) and loading then
			self:setPage(Connecting {
				App = self,
			})
		end
	end)

	self.onCanceled:Once(function()
		canceled = true
		self.isConnectedState:set(false) -- Set on cancel
	end)

	self.core:onPrompt(function(message, changes)
		loading = false

		local signal = Signal.new()
		local result = false

		self:setIcon("Warn")

		if changes then
			local options = { "Accept", "Diff", "Cancel" }
			message = describeChanges(changes)

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			local choice = signal:Wait()

			while choice == "Diff" do
				warn("This feature is not yet implemented!")
				Log.debug("You can see raw changes here:", changes)
				choice = signal:Wait()
			end

			result = choice == "Accept"
		else
			local options = { "Continue", "Cancel" }

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			result = signal:Wait() == "Continue"
		end

		-- Update isConnectedState based on the prompt outcome and actual core status
		local currentCoreStatus = self.core and self.core.status == Core.Status.Connected
		self.isConnectedState:set(result and currentCoreStatus)

		if result and currentCoreStatus then
			-- Already connected - show Connected page
			self:setPage(Connected {
				App = self,
				Project = project,
			})
			self:setIcon("Ok")
		elseif result then
			-- User chose Continue but not yet connected - show Connecting page (resume case)
			self:setPage(Connecting {
				App = self,
			})
		elseif not result then -- If user chose Cancel or did not accept/continue
			self:disconnect() -- Ensure core is stopped
			self:home() -- Go to NotConnected page
		end

		return result
	end)

	self.core:onReady(function(projectDetails)
		loading = false
		project:set(projectDetails)

		self.lastSync:set(os.time())
		self.lastSyncKind:set(Config:get("InitialSyncPriority"))

		self.isConnectedState:set(true) -- Connected!
		self:setPage(Connected {
			App = self,
			Project = project,
		})

		self:setIcon("Ok")

		-- CodexBridge is local-session based; do not monitor remote browser project switches.
	end)

	-- Handle user-facing messages from Core (e.g., conflict notifications, project changes)
	self.core:onMessage(function(messageType, messageData)
		if messageType == "project_updated" then
			local currentProject = peek(project)
			if currentProject then
				local newProject = table.clone(currentProject)
				if messageData.promptCount then
					newProject.promptCount = messageData.promptCount
				end
				if messageData.name then
					newProject.name = messageData.name
				end
				project:set(newProject)
			end
		elseif messageType == "project_changed" then
			Log.warn(
				string.format(
					"[App] Ignoring remote project change during CodexBridge session. Old: %s, New: %s",
					messageData.oldProjectName or messageData.oldProjectId or "Unknown",
					messageData.newProjectName or messageData.newProjectId or "Unknown"
				)
			)
		elseif messageType == "bridge_disconnected" then
			Log.warn("[App] CodexBridge disconnected - ending session")

			self:disconnect()

			self:setPage(Error {
				App = self,
				Message = "CodexBridge is no longer available.\n\nRestart the local listener and reconnect to continue.",
			})
		elseif messageType == "conflict" then
			-- Display conflict message to user using Error page
			Log.warn("[App] Conflict detected:", messageData.message)

			loading = false
			self.isConnectedState:set(false)

			-- Display conflict message using the Error page component
			self:setPage(Error {
				App = self,
				Message = messageData.message,
			})
		elseif messageType == "conflict_resolution" then
			-- Display conflict resolution options to user
			Log.warn("[App] Conflict resolution required:", messageData.message)

			loading = false
			self.isConnectedState:set(false)

			-- Store conflict data for resolution callbacks
			local conflictData = messageData

			-- Display conflict resolution page with action buttons
			self:setPage(ConflictResolution {
				App = self,
				Message = messageData.message,
				OnPushToVM = function()
					Log.info("[App] User chose: Push Studio to VM")
					-- Push Studio changes to VM
					if self.core and conflictData.conflictedInstances then
						self.core:pushConflictedInstancesToVM(conflictData.conflictedInstances)
					end
					-- Reconnect after resolution
					self:disconnect()
					task.wait(0.5) -- Small delay before reconnecting
					self:connect()
				end,
				OnCancel = function()
					Log.info("[App] User cancelled conflict resolution")
					-- Just go back to home without resolving
					self:disconnect()
					self:home()
				end,
			})
		end
	end)

	-- Handle Studio action completions (update UI sync status)
	self.core:onStudioAction(function(toolName, path, _timestamp)
		-- Update sync timestamp
		self.lastSync:set(os.time())

		-- Agent actions are always "Server" type (web-initiated)
		self.lastSyncKind:set("Server")

		-- Extract filename from path if available
		if path then
			local fileName = path:match("[^/]+$") or "Unknown"
			self.lastSyncedFile:set(fileName)
			Log.info(string.format("[App] Studio action completed: %s -> %s", toolName, fileName))
		end
	end)

	Log.info("[CodexBridge] Skipping remote machine checks; using local listener")

	-- Proceed with the local CodexBridge connection.
	self.core:run():catch(function(err)
		loading = false
		self.isConnectedState:set(false) -- Set on run error

		if Core.wasExitGraceful(err) or canceled then
			self:disconnect(true) -- Pass true if cancellation was the reason for graceful exit
			self:home()
			return
		end

		self:setPage(Error {
			App = self,
			Message = err.message or tostring(err),
		})

		self:setIcon("Error")

		self:disconnect() -- Ensure core is stopped after error
		-- Manual connection only: do not auto-reconnect automatically
	end)
end

function App:disconnect(cancel: boolean?)
	Log.info("[App] DISCONNECT CALLED - cancel flag:", cancel)
	self.lastUpdate = os.clock()
	self.isConnectedState:set(false) -- Explicitly set to false on disconnect

	if self.core then
		Log.info("[App] Core exists, calling stop...")
		if cancel then
			self.onCanceled:Fire()
		end

		self.core:stop()
		self.core = nil
		Log.info("[App] Core stopped and set to nil")
	else
		Log.warn("[App] No core to disconnect")
	end
end

function App:isConnected()
	return self.core and self.core.status == Core.Status.Connected
end

return App
