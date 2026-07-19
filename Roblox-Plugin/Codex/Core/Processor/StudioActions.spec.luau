
-- StudioActions.spec.luau
-- Unit tests for Studio action handlers

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudioActions = require(script.Parent.StudioActions)
local Tree = require(script.Parent.Parent.Tree)

return function()
	local tree: any
	local studioActions: any

	beforeEach(function()
		-- Create fresh tree and StudioActions for each test
		tree = Tree.new()
		studioActions = StudioActions.new(tree)

		-- Register standard services in tree
		tree:registerServices()
	end)

	describe("createScript", function()
		it("should create a Script instance", function()
			local result = studioActions:createScript({
				parentId = "sss",
				robloxClass = "Script",
				content = 'print("Hello")',
				name = "TestScript",
			})

			expect(result.status).to.equal("completed")
			expect(result.uniqueId).to.be.ok()
			expect(result.path).to.equal("ServerScriptService/TestScript")

			-- Verify instance was created
			local script = ServerScriptService:FindFirstChild("TestScript")
			expect(script).to.be.ok()
			expect(script.ClassName).to.equal("Script")
			expect(script.Source).to.equal('print("Hello")')
			expect(script:GetAttribute("CodexUniqueID")).to.equal(result.uniqueId)

			-- Cleanup
			if script then
				script:Destroy()
			end
		end)

		it("should create a LocalScript instance", function()
			local result = studioActions:createScript({
				parentId = "rs1",
				robloxClass = "LocalScript",
				content = 'print("Client")',
				name = "ClientScript",
			})

			expect(result.status).to.equal("completed")
			expect(result.uniqueId).to.be.ok()
			expect(result.path).to.equal("ReplicatedStorage/ClientScript")

			-- Verify instance was created with correct class
			local script = ReplicatedStorage:FindFirstChild("ClientScript")
			expect(script).to.be.ok()
			expect(script.ClassName).to.equal("LocalScript")

			-- Cleanup
			if script then
				script:Destroy()
			end
		end)

		it("should fail if parent not found", function()
			local result = studioActions:createScript({
				parentId = "nonexistent",
				robloxClass = "Script",
				content = "",
				name = "Test",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("updateScript", function()
		it("should update script source", function()
			-- Create test script
			local script = Instance.new("Script")
			script.Name = "UpdateTest"
			script.Source = 'print("old")'
			script:SetAttribute("CodexUniqueID", "test123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "test123", {})

			local result = studioActions:updateScript({
				uniqueId = "test123",
				content = 'print("new")',
			})

			expect(result.status).to.equal("completed")
			expect(result.path).to.equal("ServerScriptService/UpdateTest")
			expect(script.Source).to.equal('print("new")')

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if script not found", function()
			local result = studioActions:updateScript({
				uniqueId = "nonexistent",
				content = "test",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("readScript", function()
		it("should read script source", function()
			-- Create test script
			local script = Instance.new("ModuleScript")
			script.Name = "ReadTest"
			script.Source = 'return "module"'
			script:SetAttribute("CodexUniqueID", "read123")
			script.Parent = ReplicatedStorage
			tree:insertInstance(script, "read123", {})

			local result = studioActions:readScript({
				uniqueId = "read123",
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal('return "module"')
			expect(result.robloxClass).to.equal("ModuleScript")

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if script not found", function()
			local result = studioActions:readScript({
				uniqueId = "nonexistent",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)

		it("should return totalLines for full read (backward compatible)", function()
			-- Create test script with multiple lines
			local script = Instance.new("Script")
			script.Name = "TotalLinesTest"
			script.Source = "line1\nline2\nline3\nline4\nline5"
			script:SetAttribute("CodexUniqueID", "total123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "total123", {})

			local result = studioActions:readScript({
				uniqueId = "total123",
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal("line1\nline2\nline3\nline4\nline5")
			expect(result.totalLines).to.equal(5)
			-- startLine and endLine should not be set for full read
			expect(result.startLine).never.to.be.ok()
			expect(result.endLine).never.to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("should read specific line range with startLine and endLine", function()
			local script = Instance.new("Script")
			script.Name = "RangeTest"
			script.Source = "line1\nline2\nline3\nline4\nline5\nline6\nline7"
			script:SetAttribute("CodexUniqueID", "range123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "range123", {})

			local result = studioActions:readScript({
				uniqueId = "range123",
				startLine = 3,
				endLine = 5,
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal("line3\nline4\nline5")
			expect(result.totalLines).to.equal(7)
			expect(result.startLine).to.equal(3)
			expect(result.endLine).to.equal(5)

			-- Cleanup
			script:Destroy()
		end)

		it("should clamp endLine to totalLines", function()
			local script = Instance.new("Script")
			script.Name = "ClampTest"
			script.Source = "line1\nline2\nline3"
			script:SetAttribute("CodexUniqueID", "clamp123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "clamp123", {})

			local result = studioActions:readScript({
				uniqueId = "clamp123",
				startLine = 2,
				endLine = 100, -- exceeds total lines
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal("line2\nline3")
			expect(result.totalLines).to.equal(3)
			expect(result.startLine).to.equal(2)
			expect(result.endLine).to.equal(3) -- clamped to totalLines

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if startLine exceeds totalLines", function()
			local script = Instance.new("Script")
			script.Name = "ExceedTest"
			script.Source = "line1\nline2"
			script:SetAttribute("CodexUniqueID", "exceed123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "exceed123", {})

			local result = studioActions:readScript({
				uniqueId = "exceed123",
				startLine = 10,
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if endLine is less than startLine", function()
			local script = Instance.new("Script")
			script.Name = "InvalidRangeTest"
			script.Source = "line1\nline2\nline3"
			script:SetAttribute("CodexUniqueID", "invalid123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "invalid123", {})

			local result = studioActions:readScript({
				uniqueId = "invalid123",
				startLine = 3,
				endLine = 1,
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("should read only from startLine when endLine not provided", function()
			local script = Instance.new("Script")
			script.Name = "StartOnlyTest"
			script.Source = "line1\nline2\nline3\nline4\nline5"
			script:SetAttribute("CodexUniqueID", "startonly123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "startonly123", {})

			local result = studioActions:readScript({
				uniqueId = "startonly123",
				startLine = 3,
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal("line3\nline4\nline5")
			expect(result.totalLines).to.equal(5)
			expect(result.startLine).to.equal(3)
			expect(result.endLine).to.equal(5) -- defaults to totalLines

			-- Cleanup
			script:Destroy()
		end)
	end)

	describe("createInstance", function()
		it("should create a Folder instance", function()
			local result = studioActions:createInstance({
				parentId = "ws1",
				robloxClass = "Folder",
				name = "TestFolder",
			})

			expect(result.status).to.equal("completed")
			expect(result.uniqueId).to.be.ok()
			expect(result.path).to.equal("Workspace/TestFolder")

			-- Verify instance was created
			local folder = game.Workspace:FindFirstChild("TestFolder")
			expect(folder).to.be.ok()
			expect(folder.ClassName).to.equal("Folder")
			expect(folder:GetAttribute("CodexUniqueID")).to.equal(result.uniqueId)

			-- Cleanup
			if folder then
				folder:Destroy()
			end
		end)

		it("should create instance with attributes", function()
			local result = studioActions:createInstance({
				parentId = "ws1",
				robloxClass = "Part",
				name = "AttributePart",
				attributes = {
					Health = 100,
					Team = "Red",
				},
			})

			expect(result.status).to.equal("completed")

			-- Verify attributes
			local part = game.Workspace:FindFirstChild("AttributePart")
			expect(part).to.be.ok()
			expect(part:GetAttribute("Health")).to.equal(100)
			expect(part:GetAttribute("Team")).to.equal("Red")

			-- Cleanup
			if part then
				part:Destroy()
			end
		end)

		it("should create instance with properties", function()
			local result = studioActions:createInstance({
				parentId = "ws1",
				robloxClass = "Part",
				name = "PropertyPart",
				properties = {
					Color = { 255, 0, 0 }, -- Red (RGB 0-255)
					Size = { 4, 2, 4 },
				},
			})

			expect(result.status).to.equal("completed")

			-- Verify properties
			local part = game.Workspace:FindFirstChild("PropertyPart") :: Part
			expect(part).to.be.ok()
			expect(part.Color).to.equal(Color3.fromRGB(255, 0, 0))
			expect(part.Size).to.equal(Vector3.new(4, 2, 4))

			-- Cleanup
			if part then
				part:Destroy()
			end
		end)

		it("should create ParticleEmitter with complex properties (LEMON-1074 regression test)", function()
			local result = studioActions:createInstance({
				parentId = "ws1",
				robloxClass = "ParticleEmitter",
				name = "TestEmitter",
				properties = {
					Enabled = false,
					Rate = 50,
					Lifetime = { 1, 2 }, -- NumberRange
					Speed = { 20, 30 }, -- NumberRange
					SpreadAngle = { 180, 180 }, -- Vector2
					Color = { { 255, 0, 0 }, { 255, 255, 0 }, { 0, 0, 255 } }, -- ColorSequence
					Size = { 0.5, 2 }, -- NumberSequence
					Transparency = { 0, 1 }, -- NumberSequence
				},
			})

			expect(result.status).to.equal("completed")

			-- Verify ParticleEmitter was created with all properties
			local emitter = game.Workspace:FindFirstChild("TestEmitter") :: ParticleEmitter
			expect(emitter).to.be.ok()
			expect(emitter.ClassName).to.equal("ParticleEmitter")

			-- Verify complex property types were converted correctly
			expect(emitter.Enabled).to.equal(false)
			expect(emitter.Rate).to.equal(50)

			-- NumberRange properties
			expect(typeof(emitter.Lifetime)).to.equal("NumberRange")
			expect(emitter.Lifetime.Min).to.equal(1)
			expect(emitter.Lifetime.Max).to.equal(2)

			expect(typeof(emitter.Speed)).to.equal("NumberRange")
			expect(emitter.Speed.Min).to.equal(20)
			expect(emitter.Speed.Max).to.equal(30)

			-- Vector2 property
			expect(typeof(emitter.SpreadAngle)).to.equal("Vector2")
			expect(emitter.SpreadAngle.X).to.equal(180)
			expect(emitter.SpreadAngle.Y).to.equal(180)

			-- ColorSequence property
			expect(typeof(emitter.Color)).to.equal("ColorSequence")
			expect(#emitter.Color.Keypoints).to.equal(3)

			-- NumberSequence properties
			expect(typeof(emitter.Size)).to.equal("NumberSequence")
			expect(#emitter.Size.Keypoints).to.equal(2)

			expect(typeof(emitter.Transparency)).to.equal("NumberSequence")
			expect(#emitter.Transparency.Keypoints).to.equal(2)

			-- Cleanup
			if emitter then
				emitter:Destroy()
			end
		end)

		it("should fail if parent not found", function()
			local result = studioActions:createInstance({
				parentId = "nonexistent",
				robloxClass = "Folder",
				name = "Test",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("updateInstance", function()
		it("should update instance attributes", function()
			-- Create test instance
			local part = Instance.new("Part")
			part.Name = "UpdateAttributeTest"
			part:SetAttribute("CodexUniqueID", "attr123")
			part:SetAttribute("OldValue", 50)
			part.Parent = game.Workspace
			tree:insertInstance(part, "attr123", {})

			local result = studioActions:updateInstance({
				uniqueId = "attr123",
				attributes = {
					OldValue = 100,
					NewValue = "test",
				},
			})

			expect(result.status).to.equal("completed")
			expect(part:GetAttribute("OldValue")).to.equal(100)
			expect(part:GetAttribute("NewValue")).to.equal("test")

			-- Cleanup
			part:Destroy()
		end)

		it("should update instance properties", function()
			-- Create test instance
			local part = Instance.new("Part")
			part.Name = "UpdatePropertyTest"
			part:SetAttribute("CodexUniqueID", "prop123")
			part.Color = Color3.fromRGB(255, 255, 255)
			part.Parent = game.Workspace
			tree:insertInstance(part, "prop123", {})

			local result = studioActions:updateInstance({
				uniqueId = "prop123",
				properties = {
					Color = { 0, 255, 0 }, -- Green (RGB 0-255)
				},
			})

			expect(result.status).to.equal("completed")
			expect(part.Color).to.equal(Color3.fromRGB(0, 255, 0))

			-- Cleanup
			part:Destroy()
		end)

		it("should fail if instance not found", function()
			local result = studioActions:updateInstance({
				uniqueId = "nonexistent",
				attributes = { test = 1 },
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("readInstance", function()
		it("should read instance attributes and properties", function()
			-- Create test instance
			local part = Instance.new("Part")
			part.Name = "ReadInstanceTest"
			part:SetAttribute("CodexUniqueID", "read456")
			part:SetAttribute("Health", 75)
			part.Color = Color3.fromRGB(0, 0, 255)
			part.Size = Vector3.new(2, 2, 2)
			part.Parent = game.Workspace
			tree:insertInstance(part, "read456", {})

			local result = studioActions:readInstance({
				uniqueId = "read456",
			})

			expect(result.status).to.equal("completed")
			expect(result.robloxClass).to.equal("Part")
			expect(result.attributes).to.be.ok()
			expect(result.attributes.Health).to.equal(75)

			-- Properties should be returned for BasePart
			if result.properties then
				expect(result.properties.Size).to.be.ok()
				expect(result.properties.Color).to.be.ok()
			end

			-- Cleanup
			part:Destroy()
		end)

		it("should fail if instance not found", function()
			local result = studioActions:readInstance({
				uniqueId = "nonexistent",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("move", function()
		it("should move instance to new parent", function()
			-- Create test instances
			local folder = Instance.new("Folder")
			folder.Name = "MoveTest"
			folder:SetAttribute("CodexUniqueID", "move123")
			folder.Parent = ServerScriptService
			tree:insertInstance(folder, "move123", {})

			local result = studioActions:move({
				uniqueId = "move123",
				newParentId = "ws1",
			})

			expect(result.status).to.equal("completed")
			expect(result.oldPath).to.equal("ServerScriptService/MoveTest")
			expect(result.newPath).to.equal("Workspace/MoveTest")
			expect(folder.Parent).to.equal(game.Workspace)

			-- Cleanup
			folder:Destroy()
		end)

		it("should rename instance", function()
			-- Create test instance
			local folder = Instance.new("Folder")
			folder.Name = "OldName"
			folder:SetAttribute("CodexUniqueID", "rename123")
			folder.Parent = ServerScriptService
			tree:insertInstance(folder, "rename123", {})

			local result = studioActions:move({
				uniqueId = "rename123",
				newParentId = "sss",
				newName = "NewName",
			})

			expect(result.status).to.equal("completed")
			expect(result.oldPath).to.equal("ServerScriptService/OldName")
			expect(result.newPath).to.equal("ServerScriptService/NewName")
			expect(folder.Name).to.equal("NewName")

			-- Cleanup
			folder:Destroy()
		end)

		it("should fail if instance not found", function()
			local result = studioActions:move({
				uniqueId = "nonexistent",
				newParentId = "ws1",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)

		it("should fail if new parent not found", function()
			-- Create test instance
			local folder = Instance.new("Folder")
			folder.Name = "Test"
			folder:SetAttribute("CodexUniqueID", "test999")
			folder.Parent = ServerScriptService
			tree:insertInstance(folder, "test999", {})

			local result = studioActions:move({
				uniqueId = "test999",
				newParentId = "nonexistent",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()

			-- Cleanup
			folder:Destroy()
		end)
	end)

	describe("delete", function()
		it("should delete instance", function()
			-- Create test instance
			local folder = Instance.new("Folder")
			folder.Name = "DeleteTest"
			folder:SetAttribute("CodexUniqueID", "del123")
			folder.Parent = game.Workspace
			tree:insertInstance(folder, "del123", {})

			local result = studioActions:delete({
				uniqueId = "del123",
			})

			expect(result.status).to.equal("completed")
			expect(result.path).to.equal("Workspace/DeleteTest")
			expect(result.robloxClass).to.equal("Folder")
			expect(game.Workspace:FindFirstChild("DeleteTest")).never.to.be.ok()
		end)

		it("should fail if instance not found", function()
			local result = studioActions:delete({
				uniqueId = "nonexistent",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("list", function()
		it("should list children of instance", function()
			-- Create test instances
			local folder = Instance.new("Folder")
			folder.Name = "Parent"
			folder:SetAttribute("CodexUniqueID", "parent123")
			folder.Parent = game.Workspace
			tree:insertInstance(folder, "parent123", {})

			local child1 = Instance.new("Part")
			child1.Name = "Child1"
			child1:SetAttribute("CodexUniqueID", "child1")
			child1.Parent = folder
			tree:insertInstance(child1, "child1", {})

			local child2 = Instance.new("Script")
			child2.Name = "Child2"
			child2:SetAttribute("CodexUniqueID", "child2")
			child2.Parent = folder
			tree:insertInstance(child2, "child2", {})

			local result = studioActions:list({
				uniqueId = "parent123",
			})

			expect(result.status).to.equal("completed")
			expect(result.children).to.be.ok()
			expect(#result.children).to.equal(2)

			-- Verify children data
			local child1Data = nil
			local child2Data = nil
			for _, child in ipairs(result.children) do
				if child.name == "Child1" then
					child1Data = child
				elseif child.name == "Child2" then
					child2Data = child
				end
			end

			expect(child1Data).to.be.ok()
			expect(child1Data.robloxClass).to.equal("Part")
			expect(child1Data.uniqueId).to.equal("child1")

			expect(child2Data).to.be.ok()
			expect(child2Data.robloxClass).to.equal("Script")
			expect(child2Data.uniqueId).to.equal("child2")

			-- Cleanup
			folder:Destroy()
		end)

		it("should list service folders when no uniqueId provided", function()
			local result = studioActions:list({})

			expect(result.status).to.equal("completed")
			expect(result.children).to.be.ok()
			expect(#result.children).to.be.ok() -- Should have some services
		end)

		it("should fail if instance not found", function()
			local result = studioActions:list({
				uniqueId = "nonexistent",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("importAsset", function()
		-- Note: This test requires InsertService which may not work in all test environments
		-- Skip or mark as integration test if needed

		it("should fail with invalid asset ID", function()
			local result = studioActions:importAsset({
				parentId = "ws1",
				assetId = 0, -- Invalid asset ID
				name = "TestAsset",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)

		it("should fail if parent not found", function()
			local result = studioActions:importAsset({
				parentId = "nonexistent",
				assetId = 123456,
				name = "TestAsset",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)
	end)

	describe("editScript", function()
		it("should replace single occurrence of old_string", function()
			-- Create test script
			local script = Instance.new("Script")
			script.Name = "EditTest"
			script.Source = 'local damage = 10\nprint("Damage:", damage)'
			script:SetAttribute("CodexUniqueID", "edit123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "edit123", {})

			local result = studioActions:editScript({
				uniqueId = "edit123",
				old_string = "local damage = 10",
				new_string = "local damage = 25",
			})

			expect(result.status).to.equal("completed")
			expect(result.path).to.equal("ServerScriptService/EditTest")
			expect(result.replacements).to.equal(1)
			expect(script.Source).to.equal('local damage = 25\nprint("Damage:", damage)')

			-- Cleanup
			script:Destroy()
		end)

		it("should replace all occurrences with replace_all=true", function()
			-- Create test script with multiple occurrences
			local script = Instance.new("Script")
			script.Name = "ReplaceAllTest"
			script.Source = 'print("Hello")\nprint("World")\nprint("Again")'
			script:SetAttribute("CodexUniqueID", "replaceall123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "replaceall123", {})

			local result = studioActions:editScript({
				uniqueId = "replaceall123",
				old_string = "print",
				new_string = "warn",
				replace_all = true,
			})

			expect(result.status).to.equal("completed")
			expect(result.replacements).to.equal(3)
			expect(script.Source).to.equal('warn("Hello")\nwarn("World")\nwarn("Again")')

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if old_string not found", function()
			-- Create test script
			local script = Instance.new("Script")
			script.Name = "NotFoundTest"
			script.Source = 'print("Hello")'
			script:SetAttribute("CodexUniqueID", "notfound123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "notfound123", {})

			local result = studioActions:editScript({
				uniqueId = "notfound123",
				old_string = "nonexistent string",
				new_string = "replacement",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.equal("old_string not found in script content")

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if old_string appears multiple times without replace_all", function()
			-- Create test script with multiple occurrences
			local script = Instance.new("Script")
			script.Name = "MultipleTest"
			script.Source = "local x = 1\nlocal y = 1\nlocal z = 1"
			script:SetAttribute("CodexUniqueID", "multiple123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "multiple123", {})

			local result = studioActions:editScript({
				uniqueId = "multiple123",
				old_string = "local",
				new_string = "global",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.equal(
				"old_string appears multiple times. Use replace_all=true or provide more context to make it unique."
			)

			-- Cleanup
			script:Destroy()
		end)

		it("should fail if script not found", function()
			local result = studioActions:editScript({
				uniqueId = "nonexistent",
				old_string = "test",
				new_string = "replacement",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
		end)

		it("should fail if instance is not a script", function()
			-- Create a non-script instance
			local folder = Instance.new("Folder")
			folder.Name = "NotAScript"
			folder:SetAttribute("CodexUniqueID", "folder123")
			folder.Parent = ServerScriptService
			tree:insertInstance(folder, "folder123", {})

			local result = studioActions:editScript({
				uniqueId = "folder123",
				old_string = "test",
				new_string = "replacement",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.equal("Instance is not a script: folder123")

			-- Cleanup
			folder:Destroy()
		end)

		it("should handle adding new code at the end of script", function()
			-- Create test script
			local script = Instance.new("ModuleScript")
			script.Name = "ModuleTest"
			script.Source = "local module = {}\n\nreturn module"
			script:SetAttribute("CodexUniqueID", "module123")
			script.Parent = ReplicatedStorage
			tree:insertInstance(script, "module123", {})

			local result = studioActions:editScript({
				uniqueId = "module123",
				old_string = "return module",
				new_string = "function module.newFeature()\n\treturn true\nend\n\nreturn module",
			})

			expect(result.status).to.equal("completed")
			expect(result.replacements).to.equal(1)
			expect(script.Source).to.equal(
				"local module = {}\n\nfunction module.newFeature()\n\treturn true\nend\n\nreturn module"
			)

			-- Cleanup
			script:Destroy()
		end)

		it("should handle special characters in replacement strings", function()
			-- Create test script
			local script = Instance.new("Script")
			script.Name = "SpecialCharsTest"
			script.Source = 'local pattern = "test"'
			script:SetAttribute("CodexUniqueID", "special123")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "special123", {})

			local result = studioActions:editScript({
				uniqueId = "special123",
				old_string = '"test"',
				new_string = '"[%w+].-test"',
			})

			expect(result.status).to.equal("completed")
			expect(result.replacements).to.equal(1)
			expect(script.Source).to.equal('local pattern = "[%w+].-test"')

			-- Cleanup
			script:Destroy()
		end)
	end)

	describe("grep", function()
		it("should find matches with default contextLines", function()
			-- Create test script with multiple lines
			local script = Instance.new("Script")
			script.Name = "GrepContextTest"
			script.Source = "local a = 1\nlocal b = 2\nlocal target = 3\nlocal c = 4\nlocal d = 5"
			script:SetAttribute("CodexUniqueID", "grepctx1")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "grepctx1", {})

			local result = studioActions:grep({
				query = "target",
				contextLines = 2,
			})

			expect(result.status).to.equal("completed")
			expect(result.matches).to.be.ok()
			expect(#result.matches).to.equal(1)

			local match = result.matches[1]
			expect(match.lineNumber).to.equal(3)
			expect(match.matchText).to.equal("local target = 3")
			-- contextBefore should have 2 lines before
			expect(match.contextBefore).to.be.ok()
			expect(match.contextBefore).to.equal("local a = 1\nlocal b = 2")
			-- contextAfter should have 2 lines after
			expect(match.contextAfter).to.be.ok()
			expect(match.contextAfter).to.equal("local c = 4\nlocal d = 5")

			-- Cleanup
			script:Destroy()
		end)

		it("should return no context when contextLines is 0", function()
			local script = Instance.new("Script")
			script.Name = "GrepNoContext"
			script.Source = "line1\nline2\ntarget\nline4\nline5"
			script:SetAttribute("CodexUniqueID", "grepctx2")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "grepctx2", {})

			local result = studioActions:grep({
				query = "target",
				contextLines = 0,
			})

			expect(result.status).to.equal("completed")
			expect(result.matches).to.be.ok()
			expect(#result.matches).to.equal(1)

			local match = result.matches[1]
			expect(match.lineNumber).to.equal(3)
			expect(match.matchText).to.equal("target")
			-- No context when contextLines = 0
			expect(match.contextBefore).never.to.be.ok()
			expect(match.contextAfter).never.to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("should handle match at first line (no contextBefore)", function()
			local script = Instance.new("Script")
			script.Name = "GrepFirstLine"
			script.Source = "target_first\nline2\nline3"
			script:SetAttribute("CodexUniqueID", "grepctx3")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "grepctx3", {})

			local result = studioActions:grep({
				query = "target_first",
				contextLines = 3,
			})

			expect(result.status).to.equal("completed")
			expect(#result.matches).to.equal(1)

			local match = result.matches[1]
			expect(match.lineNumber).to.equal(1)
			-- No contextBefore since match is on line 1
			expect(match.contextBefore).never.to.be.ok()
			-- contextAfter should have the remaining lines
			expect(match.contextAfter).to.be.ok()
			expect(match.contextAfter).to.equal("line2\nline3")

			-- Cleanup
			script:Destroy()
		end)

		it("should handle match at last line (no contextAfter)", function()
			local script = Instance.new("Script")
			script.Name = "GrepLastLine"
			script.Source = "line1\nline2\ntarget_last"
			script:SetAttribute("CodexUniqueID", "grepctx4")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "grepctx4", {})

			local result = studioActions:grep({
				query = "target_last",
				contextLines = 3,
			})

			expect(result.status).to.equal("completed")
			expect(#result.matches).to.equal(1)

			local match = result.matches[1]
			expect(match.lineNumber).to.equal(3)
			-- contextBefore should have the preceding lines
			expect(match.contextBefore).to.be.ok()
			expect(match.contextBefore).to.equal("line1\nline2")
			-- No contextAfter since match is on last line
			expect(match.contextAfter).never.to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("should work with backward-compatible params (no contextLines specified)", function()
			-- Verify that grep still works when contextLines is not provided
			-- Default behavior should include context (contextLines defaults to 3)
			local script = Instance.new("Script")
			script.Name = "GrepBackcompat"
			script.Source = "line1\nline2\nfindme\nline4\nline5"
			script:SetAttribute("CodexUniqueID", "grepbc1")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "grepbc1", {})

			-- Call grep without contextLines parameter (backward compatible)
			local result = studioActions:grep({
				query = "findme",
			})

			expect(result.status).to.equal("completed")
			expect(result.matches).to.be.ok()
			expect(#result.matches).to.equal(1)

			local match = result.matches[1]
			expect(match.lineNumber).to.equal(3)
			expect(match.matchText).to.equal("findme")
			-- Default contextLines=3, so context should be present
			expect(match.contextBefore).to.be.ok()
			expect(match.contextAfter).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)
	end)

	describe("serialize (GUI properties)", function()
		local HttpService = game:GetService("HttpService")

		it("should serialize Frame with GuiObject properties", function()
			local frame = Instance.new("Frame")
			frame.Name = "TestFrame"
			frame.Position = UDim2.new(0.5, 10, 0.25, 20)
			frame.Size = UDim2.new(0, 400, 0, 200)
			frame.AnchorPoint = Vector2.new(0.5, 0.5)
			frame.BackgroundColor3 = Color3.fromRGB(255, 0, 128)
			frame.BackgroundTransparency = 0.5
			frame.BorderSizePixel = 2
			frame.Visible = true
			frame.ZIndex = 5
			frame.Rotation = 45
			frame:SetAttribute("CodexUniqueID", "guiframe1")
			frame.Parent = ReplicatedStorage
			tree:insertInstance(frame, "guiframe1", {})

			local result = studioActions:serialize({ uniqueId = "guiframe1" })

			expect(result.status).to.equal("completed")
			expect(result.data).to.be.ok()

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("Frame")
			expect(data.name).to.equal("TestFrame")
			expect(data.properties).to.be.ok()

			-- Check UDim2 Position
			expect(data.properties.Position).to.be.ok()
			expect(data.properties.Position.X[1]).to.equal(0.5)
			expect(data.properties.Position.X[2]).to.equal(10)
			expect(data.properties.Position.Y[1]).to.equal(0.25)
			expect(data.properties.Position.Y[2]).to.equal(20)

			-- Check UDim2 Size
			expect(data.properties.Size).to.be.ok()
			expect(data.properties.Size.X[1]).to.equal(0)
			expect(data.properties.Size.X[2]).to.equal(400)

			-- Check Color3
			expect(data.properties.BackgroundColor3).to.be.ok()
			expect(data.properties.BackgroundColor3[1]).to.equal(255)
			expect(data.properties.BackgroundColor3[2]).to.equal(0)
			expect(data.properties.BackgroundColor3[3]).to.equal(128)

			-- Check other properties
			expect(data.properties.BackgroundTransparency).to.equal(0.5)
			expect(data.properties.Visible).to.equal(true)
			expect(data.properties.ZIndex).to.equal(5)
			expect(data.properties.Rotation).to.equal(45)
			expect(data.properties.BorderSizePixel).to.equal(2)

			-- Check AnchorPoint (Vector2)
			expect(data.properties.AnchorPoint).to.be.ok()
			expect(data.properties.AnchorPoint[1]).to.equal(0.5)
			expect(data.properties.AnchorPoint[2]).to.equal(0.5)

			-- Cleanup
			frame:Destroy()
		end)

		it("should serialize ImageLabel with image properties", function()
			local img = Instance.new("ImageLabel")
			img.Name = "TestImage"
			img.Image = "rbxassetid://6927295847"
			img.ImageColor3 = Color3.fromRGB(200, 100, 50)
			img.ImageTransparency = 0.25
			img.ScaleType = Enum.ScaleType.Tile
			img.TileSize = UDim2.new(0, 100, 0, 100)
			img.Size = UDim2.new(1, 0, 1, 0)
			img.BackgroundTransparency = 1
			img:SetAttribute("CodexUniqueID", "guiimg1")
			img.Parent = ReplicatedStorage
			tree:insertInstance(img, "guiimg1", {})

			local result = studioActions:serialize({ uniqueId = "guiimg1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("ImageLabel")
			expect(data.properties).to.be.ok()

			-- Image-specific properties
			expect(data.properties.Image).to.equal("rbxassetid://6927295847")
			expect(data.properties.ImageTransparency).to.equal(0.25)
			expect(data.properties.ScaleType).to.be.ok() -- Enum serialized as string

			-- GuiObject base properties should also be present
			expect(data.properties.Size).to.be.ok()
			expect(data.properties.BackgroundTransparency).to.equal(1)

			-- Cleanup
			img:Destroy()
		end)

		it("should serialize TextLabel with text properties", function()
			local label = Instance.new("TextLabel")
			label.Name = "TestText"
			label.Text = "Hello World"
			label.TextColor3 = Color3.fromRGB(255, 255, 0)
			label.TextSize = 24
			label.Font = Enum.Font.GothamBold
			label.TextScaled = false
			label.TextWrapped = true
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(0, 200, 0, 50)
			label:SetAttribute("CodexUniqueID", "guitxt1")
			label.Parent = ReplicatedStorage
			tree:insertInstance(label, "guitxt1", {})

			local result = studioActions:serialize({ uniqueId = "guitxt1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("TextLabel")
			expect(data.properties).to.be.ok()

			-- Text-specific properties
			expect(data.properties.Text).to.equal("Hello World")
			expect(data.properties.TextSize).to.equal(24)
			expect(data.properties.TextScaled).to.equal(false)
			expect(data.properties.TextWrapped).to.equal(true)

			-- TextColor3
			expect(data.properties.TextColor3).to.be.ok()
			expect(data.properties.TextColor3[1]).to.equal(255)
			expect(data.properties.TextColor3[2]).to.equal(255)
			expect(data.properties.TextColor3[3]).to.equal(0)

			-- Cleanup
			label:Destroy()
		end)

		it("should serialize ScreenGui with display properties", function()
			local sg = Instance.new("ScreenGui")
			sg.Name = "TestScreenGui"
			sg.DisplayOrder = 10
			sg.Enabled = false
			sg.IgnoreGuiInset = true
			sg.ResetOnSpawn = false
			sg:SetAttribute("CodexUniqueID", "guisg1")
			sg.Parent = ReplicatedStorage
			tree:insertInstance(sg, "guisg1", {})

			local result = studioActions:serialize({ uniqueId = "guisg1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("ScreenGui")
			expect(data.properties).to.be.ok()
			expect(data.properties.DisplayOrder).to.equal(10)
			expect(data.properties.Enabled).to.equal(false)
			expect(data.properties.IgnoreGuiInset).to.equal(true)
			expect(data.properties.ResetOnSpawn).to.equal(false)

			-- Cleanup
			sg:Destroy()
		end)

		it("should serialize UICorner with CornerRadius", function()
			local corner = Instance.new("UICorner")
			corner.Name = "TestCorner"
			corner.CornerRadius = UDim.new(0, 12)
			corner:SetAttribute("CodexUniqueID", "guicorner1")
			corner.Parent = ReplicatedStorage
			tree:insertInstance(corner, "guicorner1", {})

			local result = studioActions:serialize({ uniqueId = "guicorner1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("UICorner")
			expect(data.properties).to.be.ok()
			expect(data.properties.CornerRadius).to.be.ok()
			expect(data.properties.CornerRadius[1]).to.equal(0) -- Scale
			expect(data.properties.CornerRadius[2]).to.equal(12) -- Offset

			-- Cleanup
			corner:Destroy()
		end)

		it("should serialize UIStroke with stroke properties", function()
			local stroke = Instance.new("UIStroke")
			stroke.Name = "TestStroke"
			stroke.Color = Color3.fromRGB(255, 200, 50)
			stroke.Thickness = 3
			stroke.Transparency = 0.125
			stroke:SetAttribute("CodexUniqueID", "guistroke1")
			stroke.Parent = ReplicatedStorage
			tree:insertInstance(stroke, "guistroke1", {})

			local result = studioActions:serialize({ uniqueId = "guistroke1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("UIStroke")
			expect(data.properties).to.be.ok()
			expect(data.properties.Thickness).to.equal(3)
			expect(data.properties.Transparency).to.equal(0.125)
			expect(data.properties.Color).to.be.ok()
			expect(data.properties.Color[1]).to.equal(255)
			expect(data.properties.Color[2]).to.equal(200)
			expect(data.properties.Color[3]).to.equal(50)

			-- Cleanup
			stroke:Destroy()
		end)

		it("should serialize UIGradient with ColorSequence and NumberSequence", function()
			local gradient = Instance.new("UIGradient")
			gradient.Name = "TestGradient"
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
			})
			gradient.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 0.5),
			})
			gradient.Rotation = 45
			gradient:SetAttribute("CodexUniqueID", "guigrad1")
			gradient.Parent = ReplicatedStorage
			tree:insertInstance(gradient, "guigrad1", {})

			local result = studioActions:serialize({ uniqueId = "guigrad1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("UIGradient")
			expect(data.properties).to.be.ok()

			-- ColorSequence should serialize as keypoint array
			expect(data.properties.Color).to.be.ok()
			expect(#data.properties.Color).to.equal(2)
			expect(data.properties.Color[1].t).to.equal(0)
			expect(data.properties.Color[1].c[1]).to.equal(255)
			expect(data.properties.Color[2].t).to.equal(1)
			expect(data.properties.Color[2].c[3]).to.equal(255)

			-- NumberSequence should serialize as keypoint array
			expect(data.properties.Transparency).to.be.ok()
			expect(#data.properties.Transparency).to.equal(2)
			expect(data.properties.Transparency[1].t).to.equal(0)
			expect(data.properties.Transparency[1].v).to.equal(0)
			expect(data.properties.Transparency[2].t).to.equal(1)
			expect(data.properties.Transparency[2].v).to.equal(0.5)

			expect(data.properties.Rotation).to.equal(45)

			-- Cleanup
			gradient:Destroy()
		end)

		it("should serialize complete UI tree with children", function()
			-- Create a ScreenGui with children (simulates a real UI)
			local sg = Instance.new("ScreenGui")
			sg.Name = "CompleteUI"
			sg.DisplayOrder = 5
			sg:SetAttribute("CodexUniqueID", "uitree1")
			sg.Parent = ReplicatedStorage
			tree:insertInstance(sg, "uitree1", {})

			local frame = Instance.new("Frame")
			frame.Name = "Background"
			frame.Size = UDim2.new(1, 0, 1, 0)
			frame.BackgroundColor3 = Color3.fromRGB(50, 50, 80)
			frame.BackgroundTransparency = 0
			frame:SetAttribute("CodexUniqueID", "uitreef1")
			frame.Parent = sg
			tree:insertInstance(frame, "uitreef1", {})

			local label = Instance.new("TextLabel")
			label.Name = "Title"
			label.Text = "My Game"
			label.TextSize = 32
			label.Size = UDim2.new(0.5, 0, 0, 60)
			label.Position = UDim2.new(0.25, 0, 0.1, 0)
			label:SetAttribute("CodexUniqueID", "uitreel1")
			label.Parent = frame
			tree:insertInstance(label, "uitreel1", {})

			local button = Instance.new("ImageButton")
			button.Name = "PlayBtn"
			button.Image = "rbxassetid://12345"
			button.Size = UDim2.new(0, 200, 0, 60)
			button.Position = UDim2.new(0.5, -100, 0.5, 0)
			button:SetAttribute("CodexUniqueID", "uitreeb1")
			button.Parent = frame
			tree:insertInstance(button, "uitreeb1", {})

			local result = studioActions:serialize({ uniqueId = "uitree1" })

			expect(result.status).to.equal("completed")

			local data = HttpService:JSONDecode(result.data)
			expect(data.className).to.equal("ScreenGui")
			expect(data.properties.DisplayOrder).to.equal(5)

			-- Should have children
			expect(data.children).to.be.ok()
			expect(#data.children).to.equal(1) -- Background frame

			local bgFrame = data.children[1]
			expect(bgFrame.className).to.equal("Frame")
			expect(bgFrame.name).to.equal("Background")
			expect(bgFrame.properties.BackgroundColor3).to.be.ok()
			expect(bgFrame.properties.BackgroundTransparency).to.equal(0)

			-- Frame should have 2 children
			expect(bgFrame.children).to.be.ok()
			expect(#bgFrame.children).to.equal(2)

			-- Find TextLabel and ImageButton children
			local foundLabel = false
			local foundButton = false
			for _, child in ipairs(bgFrame.children) do
				if child.className == "TextLabel" then
					foundLabel = true
					expect(child.properties.Text).to.equal("My Game")
					expect(child.properties.TextSize).to.equal(32)
				elseif child.className == "ImageButton" then
					foundButton = true
					expect(child.properties.Image).to.equal("rbxassetid://12345")
				end
			end
			expect(foundLabel).to.equal(true)
			expect(foundButton).to.equal(true)

			-- Cleanup
			sg:Destroy()
		end)
	end)

	describe("stale tree entry detection (IsDescendantOf check)", function()
		-- When a user deletes a script in Studio, the tree keeps a stale reference.
		-- These tests verify that actions correctly detect destroyed instances
		-- and return "not found" instead of silently operating on stale references.

		it("updateScript should fail for destroyed script in tree", function()
			-- Create script, register in tree, then destroy (simulates user deletion)
			local script = Instance.new("Script")
			script.Name = "StaleUpdateTest"
			script.Source = 'print("original")'
			script:SetAttribute("CodexUniqueID", "stale-update")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "stale-update", {})

			-- Destroy the script (user deleted it in Studio)
			script:Destroy()

			-- Tree still has the stale reference — updateScript should detect it
			local result = studioActions:updateScript({
				uniqueId = "stale-update",
				content = 'print("new")',
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
			expect(string.find(result.error, "not found")).to.be.ok()

			-- Verify stale entry was cleaned up from tree
			expect(tree:getInstance("stale-update")).to.equal(nil)
		end)

		it("readScript should fail for destroyed script in tree", function()
			local script = Instance.new("ModuleScript")
			script.Name = "StaleReadTest"
			script.Source = 'return "module"'
			script:SetAttribute("CodexUniqueID", "stale-read")
			script.Parent = ReplicatedStorage
			tree:insertInstance(script, "stale-read", {})

			script:Destroy()

			local result = studioActions:readScript({
				uniqueId = "stale-read",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
			expect(string.find(result.error, "not found")).to.be.ok()

			-- Verify stale entry was cleaned up from tree
			expect(tree:getInstance("stale-read")).to.equal(nil)
		end)

		it("editScript should fail for destroyed script in tree", function()
			local script = Instance.new("Script")
			script.Name = "StaleEditTest"
			script.Source = 'local x = 1'
			script:SetAttribute("CodexUniqueID", "stale-edit")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "stale-edit", {})

			script:Destroy()

			local result = studioActions:editScript({
				uniqueId = "stale-edit",
				old_string = "local x = 1",
				new_string = "local x = 2",
			})

			expect(result.status).to.equal("failed")
			expect(result.error).to.be.ok()
			expect(string.find(result.error, "not found")).to.be.ok()

			-- Verify stale entry was cleaned up from tree
			expect(tree:getInstance("stale-edit")).to.equal(nil)
		end)

		it("updateScript should still work for live scripts (happy path)", function()
			local script = Instance.new("Script")
			script.Name = "LiveUpdateTest"
			script.Source = 'print("old")'
			script:SetAttribute("CodexUniqueID", "live-update")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "live-update", {})

			local result = studioActions:updateScript({
				uniqueId = "live-update",
				content = 'print("new")',
			})

			expect(result.status).to.equal("completed")
			expect(result.path).to.equal("ServerScriptService/LiveUpdateTest")
			expect(script.Source).to.equal('print("new")')

			-- Tree entry should still exist
			expect(tree:getInstance("live-update")).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("readScript should still work for live scripts (happy path)", function()
			local script = Instance.new("Script")
			script.Name = "LiveReadTest"
			script.Source = 'print("hello")'
			script:SetAttribute("CodexUniqueID", "live-read")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "live-read", {})

			local result = studioActions:readScript({
				uniqueId = "live-read",
			})

			expect(result.status).to.equal("completed")
			expect(result.content).to.equal('print("hello")')
			expect(result.robloxClass).to.equal("Script")

			-- Tree entry should still exist
			expect(tree:getInstance("live-read")).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)

		it("editScript should still work for live scripts (happy path)", function()
			local script = Instance.new("Script")
			script.Name = "LiveEditTest"
			script.Source = 'local damage = 10'
			script:SetAttribute("CodexUniqueID", "live-edit")
			script.Parent = ServerScriptService
			tree:insertInstance(script, "live-edit", {})

			local result = studioActions:editScript({
				uniqueId = "live-edit",
				old_string = "local damage = 10",
				new_string = "local damage = 25",
			})

			expect(result.status).to.equal("completed")
			expect(result.replacements).to.equal(1)
			expect(script.Source).to.equal('local damage = 25')

			-- Tree entry should still exist
			expect(tree:getInstance("live-edit")).to.be.ok()

			-- Cleanup
			script:Destroy()
		end)
	end)

	describe("readInstance (GUI properties)", function()
		it("should read Frame properties", function()
			local frame = Instance.new("Frame")
			frame.Name = "ReadFrameTest"
			frame.Position = UDim2.new(0.5, 0, 0.5, 0)
			frame.Size = UDim2.new(0, 300, 0, 150)
			frame.AnchorPoint = Vector2.new(0.5, 0.5)
			frame.BackgroundColor3 = Color3.fromRGB(100, 150, 200)
			frame.BackgroundTransparency = 0.5
			frame.Visible = true
			frame.ZIndex = 3
			frame:SetAttribute("CodexUniqueID", "readgui1")
			frame.Parent = ReplicatedStorage
			tree:insertInstance(frame, "readgui1", {})

			local result = studioActions:readInstance({ uniqueId = "readgui1" })

			expect(result.status).to.equal("completed")
			expect(result.robloxClass).to.equal("Frame")
			expect(result.properties).to.be.ok()

			-- Check UDim2 Position
			expect(result.properties.Position).to.be.ok()
			expect(result.properties.Position.X[1]).to.equal(0.5)
			expect(result.properties.Position.X[2]).to.equal(0)

			-- Check UDim2 Size
			expect(result.properties.Size).to.be.ok()
			expect(result.properties.Size.X[2]).to.equal(300)

			-- Check Color3
			expect(result.properties.BackgroundColor3).to.be.ok()
			expect(math.floor(result.properties.BackgroundColor3[1])).to.equal(100)

			expect(result.properties.BackgroundTransparency).to.equal(0.5)
			expect(result.properties.Visible).to.equal(true)
			expect(result.properties.ZIndex).to.equal(3)

			-- Cleanup
			frame:Destroy()
		end)

		it("should read ImageLabel properties", function()
			local img = Instance.new("ImageLabel")
			img.Name = "ReadImageTest"
			img.Image = "rbxassetid://99999"
			img.ImageTransparency = 0.5
			img.ScaleType = Enum.ScaleType.Tile
			img.TileSize = UDim2.new(0, 50, 0, 50)
			img.Size = UDim2.new(1, 0, 1, 0)
			img:SetAttribute("CodexUniqueID", "readgui2")
			img.Parent = ReplicatedStorage
			tree:insertInstance(img, "readgui2", {})

			local result = studioActions:readInstance({ uniqueId = "readgui2" })

			expect(result.status).to.equal("completed")
			expect(result.robloxClass).to.equal("ImageLabel")
			expect(result.properties).to.be.ok()

			expect(result.properties.Image).to.equal("rbxassetid://99999")
			expect(result.properties.ImageTransparency).to.equal(0.5)
			expect(result.properties.ScaleType).to.equal("Tile")

			-- TileSize as UDim2
			expect(result.properties.TileSize).to.be.ok()
			expect(result.properties.TileSize.X[2]).to.equal(50)

			-- Cleanup
			img:Destroy()
		end)

		it("should read TextLabel properties", function()
			local label = Instance.new("TextLabel")
			label.Name = "ReadTextTest"
			label.Text = "Test Label"
			label.TextColor3 = Color3.fromRGB(255, 0, 0)
			label.TextSize = 18
			label.Font = Enum.Font.GothamBold
			label.TextScaled = true
			label:SetAttribute("CodexUniqueID", "readgui3")
			label.Parent = ReplicatedStorage
			tree:insertInstance(label, "readgui3", {})

			local result = studioActions:readInstance({ uniqueId = "readgui3" })

			expect(result.status).to.equal("completed")
			expect(result.robloxClass).to.equal("TextLabel")
			expect(result.properties).to.be.ok()

			expect(result.properties.Text).to.equal("Test Label")
			expect(result.properties.TextColor3).to.be.ok()
			expect(result.properties.TextColor3[1]).to.equal(255)
			expect(result.properties.TextSize).to.equal(18)
			expect(result.properties.Font).to.equal("GothamBold")
			expect(result.properties.TextScaled).to.equal(true)

			-- Cleanup
			label:Destroy()
		end)

		it("should read ScreenGui properties", function()
			local sg = Instance.new("ScreenGui")
			sg.Name = "ReadScreenGuiTest"
			sg.DisplayOrder = 42
			sg.Enabled = false
			sg.IgnoreGuiInset = true
			sg.ResetOnSpawn = false
			sg:SetAttribute("CodexUniqueID", "readgui4")
			sg.Parent = ReplicatedStorage
			tree:insertInstance(sg, "readgui4", {})

			local result = studioActions:readInstance({ uniqueId = "readgui4" })

			expect(result.status).to.equal("completed")
			expect(result.robloxClass).to.equal("ScreenGui")
			expect(result.properties).to.be.ok()

			expect(result.properties.DisplayOrder).to.equal(42)
			expect(result.properties.Enabled).to.equal(false)
			expect(result.properties.IgnoreGuiInset).to.equal(true)
			expect(result.properties.ResetOnSpawn).to.equal(false)

			-- Cleanup
			sg:Destroy()
		end)
	end)

	describe("readGuiTree", function()
		it("should read a nested GUI tree with PascalCase node fields", function()
			local screenGui = Instance.new("ScreenGui")
			screenGui.Name = "CodexGui"
			screenGui.DisplayOrder = 12
			screenGui:SetAttribute("CodexUniqueID", "codexguiroot")
			screenGui.Parent = ReplicatedStorage
			tree:insertInstance(screenGui, "codexguiroot", {})

			local frame = Instance.new("Frame")
			frame.Name = "Panel"
			frame.Size = UDim2.new(0, 320, 0, 180)
			frame.Position = UDim2.new(0.5, -160, 0.5, -90)
			frame.BackgroundColor3 = Color3.fromRGB(20, 30, 40)
			frame:SetAttribute("CodexUniqueID", "codexguiframe")
			frame.Parent = screenGui
			tree:insertInstance(frame, "codexguiframe", {})

			local label = Instance.new("TextLabel")
			label.Name = "Title"
			label.Text = "Inventory"
			label.TextSize = 24
			label.Size = UDim2.new(1, 0, 0, 40)
			label:SetAttribute("CodexUniqueID", "codexguititle")
			label.Parent = frame
			tree:insertInstance(label, "codexguititle", {})

			local result = studioActions:readGuiTree({
				RootUniqueId = "codexguiroot",
				MaxDepth = 4,
				IncludeText = true,
			})

			expect(result.status).to.equal("completed")
			expect(result.Root).to.be.ok()
			expect(result.Root.Name).to.equal("CodexGui")
			expect(result.Root.ClassName).to.equal("ScreenGui")
			expect(result.Root.UniqueId).to.equal("codexguiroot")
			expect(result.Root.Properties.DisplayOrder).to.equal(12)

			local frameNode = result.Root.Children[1]
			expect(frameNode.Name).to.equal("Panel")
			expect(frameNode.Properties.Size.X[2]).to.equal(320)
			expect(frameNode.Properties.Position.X[1]).to.equal(0.5)

			local labelNode = frameNode.Children[1]
			expect(labelNode.Name).to.equal("Title")
			expect(labelNode.Properties.Text).to.equal("Inventory")
			expect(labelNode.Properties.TextSize).to.equal(24)

			screenGui:Destroy()
		end)

		it("should report truncation when MaxNodes is reached", function()
			local screenGui = Instance.new("ScreenGui")
			screenGui.Name = "TruncatedGui"
			screenGui:SetAttribute("CodexUniqueID", "truncatedgui")
			screenGui.Parent = ReplicatedStorage
			tree:insertInstance(screenGui, "truncatedgui", {})

			for index = 1, 5 do
				local frame = Instance.new("Frame")
				frame.Name = "Child" .. tostring(index)
				frame:SetAttribute("CodexUniqueID", "truncatedchild" .. tostring(index))
				frame.Parent = screenGui
				tree:insertInstance(frame, "truncatedchild" .. tostring(index), {})
			end

			local result = studioActions:readGuiTree({
				RootUniqueId = "truncatedgui",
				MaxDepth = 2,
				MaxNodes = 3,
			})

			expect(result.status).to.equal("completed")
			expect(result.NodeCount).to.equal(3)
			expect(result.Truncated).to.equal(true)

			screenGui:Destroy()
		end)
	end)
end
