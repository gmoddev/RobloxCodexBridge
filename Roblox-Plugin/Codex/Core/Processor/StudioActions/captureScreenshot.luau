--!strict
-- captureScreenshot: Runs the UI Builder LocalScript in edit mode (targeting CoreGui)
-- and captures a screenshot of the rendered GUI.
--
-- Approach:
-- 1. Find the LocalScript "{templateName}_UIBuilder" in StarterPlayerScripts
-- 2. Read its .Source, patch PlayerGui → CoreGui
-- 3. Run patched code via loadstring()
-- 4. CaptureService:CaptureScreenshot()
-- 5. EditableImage scale down + ReadPixelsBuffer
-- 6. Base64 encode RGBA, return result
-- 7. Destroy temporary ScreenGui + clean up

local CaptureService = game:GetService("CaptureService")
local ContentProvider = game:GetService("ContentProvider")
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local renderContentId = require(script.Parent.renderContentId)

local function startsWith(value: string, prefix: string): boolean
	return string.sub(value, 1, #prefix) == prefix
end

local function endsWith(value: string, suffix: string): boolean
	return #value >= #suffix and string.sub(value, -#suffix) == suffix
end

-- Cleanup helper: destroy any GUIs created in CoreGui by the template
local function cleanupCoreGui(templateName: string)
	for _, child in CoreGui:GetChildren() do
		if child:IsA("ScreenGui") and (child.Name == templateName or startsWith(child.Name, templateName .. "_")) then
			child:Destroy()
		end
	end
end

local function snapshotCoreGuiChildren(): { [Instance]: boolean }
	local snapshot = {}
	for _, child in CoreGui:GetChildren() do
		snapshot[child] = true
	end
	return snapshot
end

local function getCreatedCoreGuiChildren(snapshot: { [Instance]: boolean }): { Instance }
	local created = {}
	for _, child in CoreGui:GetChildren() do
		if not snapshot[child] then
			table.insert(created, child)
		end
	end
	return created
end

local function cleanupInstances(instances: { Instance })
	for _, instance in instances do
		if instance.Parent then
			instance:Destroy()
		end
	end
end

local function findMainScreenGui(templateName: string, createdInstances: { Instance }): ScreenGui?
	local fallback: ScreenGui? = nil

	for _, instance in createdInstances do
		if instance:IsA("ScreenGui") and not endsWith(instance.Name, "_OpenButton") then
			if instance.Name == templateName then
				return instance
			end
			if startsWith(instance.Name, templateName .. "_") then
				fallback = instance
			elseif not fallback then
				fallback = instance
			end
		end
	end

	local legacyGui = CoreGui:FindFirstChild(templateName)
	if legacyGui and legacyGui:IsA("ScreenGui") then
		return legacyGui
	end

	return fallback
end

local function collectImages(instances: { Instance }): { Instance }
	local images = {}
	for _, instance in instances do
		if instance.Parent then
			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				table.insert(images, instance)
			end
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
					table.insert(images, descendant)
				end
			end
		end
	end
	return images
end

local function findTemplateModule(templateName: string): (Folder?, ModuleScript?)
	for _, folderName in { "UIs", "UITemplates" } do
		local folder = ReplicatedStorage:FindFirstChild(folderName)
		local templateModule = folder and folder:FindFirstChild(templateName)
		if folder and templateModule and templateModule:IsA("ModuleScript") then
			return folder :: Folder, templateModule
		end
	end
	return nil, nil
end

local function patchTemplateRequire(source: string, templateName: string, folderName: string, cloneName: string): string
	local replacement = 'require(game:GetService("ReplicatedStorage").' .. folderName .. "." .. cloneName .. ")"
	local patched = source
	patched = string.gsub(
		patched,
		"require%(ReplicatedStorage%." .. folderName .. "%." .. templateName .. "%)",
		replacement
	)
	patched = string.gsub(
		patched,
		'require%(game:GetService%("ReplicatedStorage"%)%.' .. folderName .. "%." .. templateName .. "%)",
		replacement
	)
	return patched
end

return function(
	_self,
	params: {
		templateName: string?,
		maxWidth: number?,
	}
): {
	status: string,
	width: number?,
	height: number?,
	data: string?,
	error: string?,
}
	local maxWidth = math.min(params.maxWidth or 1024, 2048)
	local templateName = params.templateName

	-- If templateName is provided, find and run the LocalScript
	local templateClone: ModuleScript? = nil
	local guiRoot: ScreenGui? = nil
	local wasEnabled: boolean? = nil
	local createdCoreGuiChildren: { Instance } = {}
	if templateName then
		local starterPlayerScripts = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
		if not starterPlayerScripts then
			return { status = "failed", error = "StarterPlayerScripts not found" }
		end

		local scriptName = templateName .. "_UIBuilder"
		local localScript = starterPlayerScripts:FindFirstChild(scriptName)
		if not localScript then
			return {
				status = "failed",
				error = "LocalScript '" .. scriptName .. "' not found in StarterPlayerScripts",
			}
		end

		-- Remove stale CoreGui previews from older failed captures before taking
		-- the before/after snapshot for this run.
		cleanupCoreGui(templateName)
		local coreGuiSnapshot = snapshotCoreGuiChildren()

		-- Clone the template ModuleScript to bypass Roblox's require() cache.
		-- require() caches by instance identity, so after the agent edits the
		-- template's .Source, a normal require() still returns the stale cached
		-- module. Cloning creates a fresh instance that require() treats as new.
		local templateFolder, templateModule = findTemplateModule(templateName)
		local cloneName = "_Screenshot_" .. templateName
		if templateFolder and templateModule then
			templateClone = templateModule:Clone()
			templateClone.Name = cloneName
			templateClone.Parent = templateFolder
		end

		-- Read source and patch PlayerGui → CoreGui
		local source = localScript.Source
		local patched = string.gsub(source, "Players%.LocalPlayer%.PlayerGui", 'game:GetService("CoreGui")')
		patched = string.gsub(
			patched,
			'Players%.LocalPlayer:WaitForChild%("PlayerGui"%)',
			'game:GetService("CoreGui")'
		)

		-- Patch require() to use the cloned module instead of the cached original
		if templateClone and templateFolder then
			patched = patchTemplateRequire(patched, templateName, templateFolder.Name, cloneName)
		end

		-- Compile patched code
		local fn, compileErr = loadstring(patched)
		if not fn then
			createdCoreGuiChildren = getCreatedCoreGuiChildren(coreGuiSnapshot)
			cleanupInstances(createdCoreGuiChildren)
			cleanupCoreGui(templateName)
			if templateClone then
				templateClone:Destroy()
			end
			return {
				status = "failed",
				error = "Failed to compile patched script: " .. tostring(compileErr),
			}
		end

		-- Run patched code with timeout to prevent infinite yields
		-- (e.g. WaitForChild("PlayerGui") in edit mode hangs forever and blocks the poll loop)
		local SCRIPT_TIMEOUT = 5
		local scriptOk = nil
		local scriptErr = nil
		local scriptDone = false

		local scriptThread = task.spawn(function()
			scriptOk, scriptErr = pcall(fn)
			scriptDone = true
		end)

		local waited = 0
		while not scriptDone and waited < SCRIPT_TIMEOUT do
			task.wait(0.1)
			waited += 0.1
		end

		if not scriptDone then
			-- Script is stuck (likely infinite yield from WaitForChild or similar)
			task.cancel(scriptThread)
			createdCoreGuiChildren = getCreatedCoreGuiChildren(coreGuiSnapshot)
			cleanupInstances(createdCoreGuiChildren)
			cleanupCoreGui(templateName)
			if templateClone then
				templateClone:Destroy()
			end
			return {
				status = "failed",
				error = "Script execution timed out after " .. SCRIPT_TIMEOUT .. "s (possible infinite yield)",
			}
		end

		if not scriptOk then
			createdCoreGuiChildren = getCreatedCoreGuiChildren(coreGuiSnapshot)
			cleanupInstances(createdCoreGuiChildren)
			cleanupCoreGui(templateName)
			if templateClone then
				templateClone:Destroy()
			end
			return {
				status = "failed",
				error = "Failed to run patched script: " .. tostring(scriptErr),
			}
		end

		-- Allow Fusion rendering to settle
		task.wait(0.3)
		createdCoreGuiChildren = getCreatedCoreGuiChildren(coreGuiSnapshot)

		-- Force the main template ScreenGui visible for screenshot capture.
		-- The agent may have set Enabled=false (e.g. open/close toggle).
		-- We save the original value and restore it after capture.
		guiRoot = findMainScreenGui(templateName, createdCoreGuiChildren)
		wasEnabled = nil
		if guiRoot and not guiRoot.Enabled then
			wasEnabled = false
			guiRoot.Enabled = true
			-- Give the newly-enabled GUI a frame to render
			task.wait(0.1)
		end

		-- Preload image assets so rbxassetid:// images render before capture
		local imagesToPreload = collectImages(createdCoreGuiChildren)
		if #imagesToPreload > 0 then
			Log.info("[captureScreenshot] Preloading " .. #imagesToPreload .. " images...")
			local preloadOk, preloadErr = pcall(function()
				ContentProvider:PreloadAsync(imagesToPreload)
			end)
			if not preloadOk then
				Log.warn("[captureScreenshot] Image preload failed: " .. tostring(preloadErr))
			end
			-- Extra wait for images to render after preloading
			task.wait(0.2)
		end
	end

	-- Screenshot pipeline
	local contentId = nil
	local done = false

	local captureOk, captureErr = pcall(function()
		CaptureService:CaptureScreenshot(function(id)
			contentId = id
			done = true
		end)
	end)

	if not captureOk then
		if templateName then
			cleanupInstances(createdCoreGuiChildren)
			cleanupCoreGui(templateName)
		end
		if templateClone then
			templateClone:Destroy()
		end
		return {
			status = "failed",
			error = "CaptureScreenshot failed: " .. tostring(captureErr),
		}
	end

	-- Wait for callback (max 10s)
	local elapsed = 0
	while not done and elapsed < 10 do
		task.wait(0.1)
		elapsed = elapsed + 0.1
	end

	if not done then
		if templateName then
			cleanupInstances(createdCoreGuiChildren)
			cleanupCoreGui(templateName)
		end
		if templateClone then
			templateClone:Destroy()
		end
		return {
			status = "failed",
			error = "Could not capture UI screenshot, is Studio in play test mode? Exit play test mode to capture screenshot.",
			errorCode = "screenshot_playtest_timeout",
		}
	end

	-- Create EditableImage and extract pixels via the shared renderer.
	-- ReadPixelsBuffer has a 1024 limit per dimension, so the helper tiles if needed.
	local imgOk, imgResult = pcall(renderContentId.render, contentId, maxWidth)

	-- Restore original Enabled state so we don't override the user's edits
	if wasEnabled == false and guiRoot then
		guiRoot.Enabled = false
	end

	-- Clean up GUI from CoreGui and the cloned template module
	if templateName then
		cleanupInstances(createdCoreGuiChildren)
		cleanupCoreGui(templateName)
	end
	if templateClone then
		templateClone:Destroy()
	end

	if not imgOk then
		return {
			status = "failed",
			error = "Image processing failed: " .. tostring(imgResult),
		}
	end

	if imgResult.tiles then
		Log.info(
			"[captureScreenshot] Captured "
				.. imgResult.width
				.. "x"
				.. imgResult.height
				.. " ("
				.. #imgResult.tiles
				.. " tiles)"
		)
		return {
			status = "completed",
			width = imgResult.width,
			height = imgResult.height,
			tiles = imgResult.tiles,
		}
	end

	Log.info(
		"[captureScreenshot] Captured "
			.. imgResult.width
			.. "x"
			.. imgResult.height
			.. " ("
			.. #imgResult.data
			.. " bytes base64)"
	)

	return {
		status = "completed",
		width = imgResult.width,
		height = imgResult.height,
		data = imgResult.data,
	}
end
