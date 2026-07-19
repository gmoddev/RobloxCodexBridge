--!strict
-- Unit tests for ToolboxImportProcessor based on real poll response data from debug/no-create-instance-after-toolbox-import.log

return function()
	describe("ToolboxImportProcessor.processToolboxImportEvent - Real Poll Data Integration", function()
		local Tree
		local WriteProcessor
		local tree
		local writeProcessor
		local replicatedStorage
		local createdInstances

		beforeAll(function()
			-- Load real modules using relative paths
			-- script is ToolboxImportProcessor.spec.luau
			-- script.Parent is Write/
			-- script.Parent.Parent is Processor/
			-- script.Parent.Parent.Parent is Core/
			local Codex = script:FindFirstAncestor("Codex")
			Tree = require(Codex.Core.Tree)
			WriteProcessor = require(script.Parent)

			-- Use actual Roblox services
			replicatedStorage = game:GetService("ReplicatedStorage")
		end)

		beforeEach(function()
			-- Create fresh Tree and WriteProcessor for each test
			tree = Tree.new()

			-- Create mock ProjectApi (empty - no snapshot APIs needed)
			local mockProjectApi = {}

			writeProcessor = WriteProcessor.new(tree, mockProjectApi)

			-- Track instances created during tests for cleanup
			createdInstances = {}
		end)

		afterEach(function()
			-- Clean up test instances after each test
			for _, instance in ipairs(createdInstances) do
				if instance and instance.Parent then
					instance:Destroy()
				end
			end
			createdInstances = {}
		end)

		it("should import a toolbox asset (Sword from poll data)", function()
			-- Register ReplicatedStorage in tree
			local rsId = "rs1"
			tree:insertInstance(replicatedStorage, rsId, {}, os.clock() * 1000)

			-- Real data from debug/no-create-instance-after-toolbox-import.log line 75
			local payload = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage",
				name = "Sword",
				uniqueId = "EOI3Y3ANCKLH",
			}

			local success = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload)

			-- Verify import was successful
			expect(success).to.equal(true)

			-- Find the imported instance
			local importedInstance = replicatedStorage:FindFirstChild("Sword")
			table.insert(createdInstances, importedInstance)

			-- Verify instance was created
			expect(importedInstance).to.be.ok()
			expect(importedInstance.Name).to.equal("Sword")
			expect(importedInstance.Parent).to.equal(replicatedStorage)

			-- Verify uniqueId attribute was set (using CodexUniqueID)
			expect(importedInstance:GetAttribute("CodexUniqueID")).to.equal("EOI3Y3ANCKLH")
			-- _serverCreated should NOT be set for toolbox imports (VM needs to learn the structure)
			expect(importedInstance:GetAttribute("_serverCreated")).never.to.be.ok()

			-- Verify assetId was persisted for traceability
			expect(importedInstance:GetAttribute("assetId")).to.equal("47433")

			-- Note: Tree registration is NOT done by ToolboxImportProcessor
			-- It happens later when ReadProcessor processes the Watcher Add event
		end)

		it("should create new instance with same name when instance with same name exists", function()
			-- Register ReplicatedStorage in tree
			local rsId = "rs1"
			tree:insertInstance(replicatedStorage, rsId, {}, os.clock() * 1000)

			-- Create an existing instance without uniqueId
			local existingTool = Instance.new("Tool")
			existingTool.Name = "ExistingTool"
			existingTool.Parent = replicatedStorage
			table.insert(createdInstances, existingTool)

			-- Verify it doesn't have a uniqueId yet
			expect(existingTool:GetAttribute("CodexUniqueID")).never.to.be.ok()

			-- Import with same name (should create new instance with same name)
			local payload = {
				assetId = 47433, -- Known working asset
				destinationPath = "ReplicatedStorage",
				name = "ExistingTool",
				uniqueId = "NEWIMPORT001",
			}

			local success = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload)

			-- Should succeed
			expect(success).to.equal(true)

			-- Original instance should remain unchanged (no uniqueId)
			expect(existingTool:GetAttribute("CodexUniqueID")).never.to.be.ok()
			expect(existingTool.Name).to.equal("ExistingTool")

			-- Find the new imported instance by uniqueId attribute
			local importedInstance = nil
			for _, child in ipairs(replicatedStorage:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "NEWIMPORT001" then
					importedInstance = child
					break
				end
			end
			table.insert(createdInstances, importedInstance)
			expect(importedInstance).to.be.ok()
			expect(importedInstance.Name).to.equal("ExistingTool") -- Same name as original
			expect(importedInstance:GetAttribute("CodexUniqueID")).to.equal("NEWIMPORT001")
			-- _serverCreated should NOT be set for toolbox imports (VM needs to learn the structure)
			expect(importedInstance:GetAttribute("_serverCreated")).never.to.be.ok()
			expect(importedInstance:GetAttribute("assetId")).to.equal("47433")

			-- Note: Tree registration is NOT done by ToolboxImportProcessor
			-- It happens later when ReadProcessor processes the Watcher Add event

			-- Verify TWO instances exist with the same name
			local count = 0
			for _, child in ipairs(replicatedStorage:GetChildren()) do
				if child.Name == "ExistingTool" then
					count = count + 1
				end
			end
			expect(count).to.equal(2)
		end)

		it("should skip import when instance with same uniqueId already exists", function()
			-- Register ReplicatedStorage in tree
			local rsId = "rs1"
			tree:insertInstance(replicatedStorage, rsId, {}, os.clock() * 1000)

			-- First import
			local payload1 = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage",
				name = "FirstImport",
				uniqueId = "SAMEID12345",
			}

			local success1 = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload1)
			expect(success1).to.equal(true)

			local firstInstance = replicatedStorage:FindFirstChild("FirstImport")
			table.insert(createdInstances, firstInstance)
			expect(firstInstance).to.be.ok()
			expect(firstInstance:GetAttribute("CodexUniqueID")).to.equal("SAMEID12345")

			-- Try to import again with same uniqueId but different name
			local payload2 = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage",
				name = "SecondImport",
				uniqueId = "SAMEID12345", -- Same uniqueId
			}

			local success2 = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload2)

			-- Should succeed (returns true) but not create a new instance
			expect(success2).to.equal(true)

			-- Should NOT have created a second instance with the new name
			local secondInstance = replicatedStorage:FindFirstChild("SecondImport")
			expect(secondInstance).never.to.be.ok()

			-- Original instance should still exist unchanged
			expect(firstInstance.Parent).to.equal(replicatedStorage)
			expect(firstInstance.Name).to.equal("FirstImport")
			expect(firstInstance:GetAttribute("CodexUniqueID")).to.equal("SAMEID12345")

			-- Verify only ONE instance exists with this uniqueId
			local count = 0
			for _, child in ipairs(replicatedStorage:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "SAMEID12345" then
					count = count + 1
				end
			end
			expect(count).to.equal(1)
		end)

		it("should allow duplicate names with different uniqueIds", function()
			-- Register ReplicatedStorage in tree
			local rsId = "rs1"
			tree:insertInstance(replicatedStorage, rsId, {}, os.clock() * 1000)

			-- Create first instance
			local payload1 = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage",
				name = "DuplicateName",
				uniqueId = "UNIQUE000001",
			}

			local success1 = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload1)
			expect(success1).to.equal(true)

			-- Find first instance by uniqueId
			local instance1 = nil
			for _, child in ipairs(replicatedStorage:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "UNIQUE000001" then
					instance1 = child
					break
				end
			end
			table.insert(createdInstances, instance1)
			expect(instance1).to.be.ok()
			expect(instance1.Name).to.equal("DuplicateName")

			-- Create second instance with same name but different uniqueId
			local payload2 = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage",
				name = "DuplicateName",
				uniqueId = "UNIQUE000002",
			}

			local success2 = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload2)
			expect(success2).to.equal(true)

			-- Find second instance by uniqueId
			local instance2 = nil
			for _, child in ipairs(replicatedStorage:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "UNIQUE000002" then
					instance2 = child
					break
				end
			end
			table.insert(createdInstances, instance2)
			expect(instance2).to.be.ok()
			expect(instance2.Name).to.equal("DuplicateName") -- Same name as first

			-- Verify both instances exist with different uniqueIds
			expect(instance1:GetAttribute("CodexUniqueID")).to.equal("UNIQUE000001")
			expect(instance2:GetAttribute("CodexUniqueID")).to.equal("UNIQUE000002")

			-- Verify they are different instances
			expect(instance1).never.to.equal(instance2)
		end)

		it("should NOT set _serverCreated on imported assets or intermediate folders (for VM push-back)", function()
			-- Register ReplicatedStorage in tree
			local rsId = "rs1"
			tree:insertInstance(replicatedStorage, rsId, {}, os.clock() * 1000)

			-- Import to a nested path that requires creating intermediate folders
			local payload = {
				assetId = 47433,
				destinationPath = "ReplicatedStorage/Assets/Weapons",
				name = "ImportedTool",
				uniqueId = "PUSHBACK001",
			}

			local success = writeProcessor.toolboxImportProcessor:processToolboxImportEvent(payload)
			expect(success).to.equal(true)

			-- Find all created instances
			local assetsFolder = replicatedStorage:FindFirstChild("Assets")
			local weaponsFolder = assetsFolder and assetsFolder:FindFirstChild("Weapons")
			local importedTool = weaponsFolder and weaponsFolder:FindFirstChild("ImportedTool")

			-- Track for cleanup
			table.insert(createdInstances, assetsFolder)

			-- Verify all instances were created
			expect(assetsFolder).to.be.ok()
			expect(weaponsFolder).to.be.ok()
			expect(importedTool).to.be.ok()

			-- CRITICAL: None of the instances should have _serverCreated attribute
			-- This allows the Watcher to detect them and push back to VM
			expect(assetsFolder:GetAttribute("_serverCreated")).never.to.be.ok()
			expect(weaponsFolder:GetAttribute("_serverCreated")).never.to.be.ok()
			expect(importedTool:GetAttribute("_serverCreated")).never.to.be.ok()

			-- Verify the imported tool has the uniqueId
			expect(importedTool:GetAttribute("CodexUniqueID")).to.equal("PUSHBACK001")
			expect(importedTool:GetAttribute("assetId")).to.equal("47433")

			-- Note: Tree registration is NOT done by ToolboxImportProcessor
			-- It happens later when ReadProcessor processes the Watcher Add event
		end)
	end)
end
