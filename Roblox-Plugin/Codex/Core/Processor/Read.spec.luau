--!strict
-- Unit tests for ReadProcessor to ensure correct parent ID handling

return function()
	describe("ReadProcessor.onAdd - Parent ID Resolution", function()
		local Tree
		local ReadProcessor
		local UniqueIdHelpers
		local tree
		local readProcessor
		local serverScriptService
		local createdInstances

		beforeAll(function()
			local Codex = script:FindFirstAncestor("Codex")
			Tree = require(Codex.Core.Tree)
			ReadProcessor = require(script.Parent.Read)
			UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

			serverScriptService = game:GetService("ServerScriptService")
		end)

		beforeEach(function()
			tree = Tree.new()
			readProcessor = ReadProcessor.new(tree)
			createdInstances = {}
		end)

		afterEach(function()
			-- Clean up test instances
			for _, instance in ipairs(createdInstances) do
				if instance and instance.Parent then
					instance:Destroy()
				end
			end
			createdInstances = {}
		end)

		it("should generate uniqueId for parent if missing (ROOT_DATAMODEL_ID fix)", function()
			-- Register ServerScriptService in tree as a service
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create parent Folder WITHOUT uniqueId attribute (simulates the bug scenario)
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "ParentFolder"
			parentFolder.Parent = serverScriptService
			table.insert(createdInstances, parentFolder)

			-- Register parent in tree WITHOUT uniqueId attribute
			local tempParentId = "TEMP12345678"
			tree:insertInstance(parentFolder, tempParentId, {}, os.clock() * 1000)

			-- BEFORE THE FIX: Parent would NOT have a uniqueId attribute
			local parentUidBefore = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUidBefore).never.to.be.ok() -- Should be nil before processing child

			-- Create child Script
			local childScript = Instance.new("ModuleScript")
			childScript.Name = "ChildScript"
			childScript.Parent = parentFolder
			table.insert(createdInstances, childScript)

			-- Process child - THE FIX should auto-generate parent's uniqueId
			readProcessor:onAdd(childScript) -- Trigger processing

			-- VERIFY THE FIX: Parent should now have a uniqueId attribute
			local parentUidAfter = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUidAfter).to.be.ok() -- Should now have a uniqueId
			expect(parentUidAfter).never.to.equal("ROOT_DATAMODEL_ID") -- Should NOT be ROOT_DATAMODEL_ID

			-- Verify it's a valid 12-character uniqueId
			expect(#parentUidAfter).to.equal(12)

			-- Verify it contains only valid base32 characters
			local isValidBase32 = string.match(parentUidAfter, "^[A-Za-z0-9]+$") ~= nil
			expect(isValidBase32).to.equal(true)
		end)

		it("should use existing uniqueId from parent attribute", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create parent Folder WITH uniqueId attribute
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "MyFolder"
			UniqueIdHelpers.setUniqueId(parentFolder, "FOLDER123456")
			parentFolder.Parent = serverScriptService
			table.insert(createdInstances, parentFolder)

			-- Register parent in tree
			local parentId = "FOLDER123456"
			tree:insertInstance(parentFolder, parentId, {}, os.clock() * 1000)

			-- Create child Script
			local childScript = Instance.new("ModuleScript")
			childScript.Name = "MyScript"
			childScript.Parent = parentFolder
			table.insert(createdInstances, childScript)

			-- Process child
			readProcessor:onAdd(childScript) -- Trigger processing

			-- Verify parent's uniqueId didn't change (should still be FOLDER123456)
			local parentUid = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUid).to.equal("FOLDER123456")

			-- Verify child also got a uniqueId
			local childUid = UniqueIdHelpers.getUniqueId(childScript)
			expect(childUid).to.be.ok()
			expect(#childUid).to.equal(12)
		end)

		it("should handle parent NOT in tree (original bug scenario)", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create parent Folder WITHOUT registering in tree AND without uniqueId
			-- This is the EXACT scenario that caused ROOT_DATAMODEL_ID bug
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "UnregisteredParent"
			parentFolder.Parent = serverScriptService
			table.insert(createdInstances, parentFolder)

			-- Do NOT register parent in tree (simulates rapid batch creation)

			-- Create child Script
			local childScript = Instance.new("ModuleScript")
			childScript.Name = "OrphanedChild"
			childScript.Parent = parentFolder
			table.insert(createdInstances, childScript)

			-- Before fix: parent would have no uniqueId, child would get ROOT_DATAMODEL_ID
			local parentUidBefore = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUidBefore).never.to.be.ok()

			-- Process child
			readProcessor:onAdd(childScript)

			-- After fix: parent should have auto-generated uniqueId
			local parentUidAfter = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUidAfter).to.be.ok()
			expect(parentUidAfter).never.to.equal("ROOT_DATAMODEL_ID")
			expect(#parentUidAfter).to.equal(12)

			-- Child should also have uniqueId
			local childUid = UniqueIdHelpers.getUniqueId(childScript)
			expect(childUid).to.be.ok()
			expect(#childUid).to.equal(12)
		end)

		it("should handle multiple children with same parent", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create parent WITHOUT uniqueId
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "SharedParent"
			parentFolder.Parent = serverScriptService
			table.insert(createdInstances, parentFolder)

			local tempParentId = "SHARED123456"
			tree:insertInstance(parentFolder, tempParentId, {}, os.clock() * 1000)

			-- Create multiple children
			local child1 = Instance.new("ModuleScript")
			child1.Name = "Child1"
			child1.Parent = parentFolder
			table.insert(createdInstances, child1)

			local child2 = Instance.new("ModuleScript")
			child2.Name = "Child2"
			child2.Parent = parentFolder
			table.insert(createdInstances, child2)

			local child3 = Instance.new("ModuleScript")
			child3.Name = "Child3"
			child3.Parent = parentFolder
			table.insert(createdInstances, child3)

			-- Process first child - should generate parent uniqueId
			readProcessor:onAdd(child1)

			local parentUid = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUid).to.be.ok()
			expect(#parentUid).to.equal(12)

			-- Process remaining children - should NOT regenerate parent uniqueId
			readProcessor:onAdd(child2)
			readProcessor:onAdd(child3)

			-- All children processed, parent uniqueId should remain the same
			local parentUidAfter = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUidAfter).to.equal(parentUid) -- Should be unchanged

			-- All children should have uniqueIds
			expect(UniqueIdHelpers.getUniqueId(child1)).to.be.ok()
			expect(UniqueIdHelpers.getUniqueId(child2)).to.be.ok()
			expect(UniqueIdHelpers.getUniqueId(child3)).to.be.ok()
		end)

		it("should handle nested hierarchy (grandparent -> parent -> child)", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create grandparent Folder WITH uniqueId
			local grandparentFolder = Instance.new("Folder")
			grandparentFolder.Name = "Grandparent"
			UniqueIdHelpers.setUniqueId(grandparentFolder, "GRAND1234567")
			grandparentFolder.Parent = serverScriptService
			table.insert(createdInstances, grandparentFolder)

			local grandparentId = "GRAND1234567"
			tree:insertInstance(grandparentFolder, grandparentId, {}, os.clock() * 1000)

			-- Create parent Folder WITHOUT uniqueId
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "Parent"
			parentFolder.Parent = grandparentFolder
			table.insert(createdInstances, parentFolder)

			local tempParentId = "TEMPPARENT12"
			tree:insertInstance(parentFolder, tempParentId, {}, os.clock() * 1000)

			-- Create child Script
			local childScript = Instance.new("ModuleScript")
			childScript.Name = "GrandChild"
			childScript.Parent = parentFolder
			table.insert(createdInstances, childScript)

			-- Process child - should generate parent's uniqueId but NOT grandparent's
			readProcessor:onAdd(childScript)

			-- Verify grandparent uniqueId unchanged
			expect(UniqueIdHelpers.getUniqueId(grandparentFolder)).to.equal("GRAND1234567")

			-- Verify parent got auto-generated uniqueId
			local parentUid = UniqueIdHelpers.getUniqueId(parentFolder)
			expect(parentUid).to.be.ok()
			expect(parentUid).never.to.equal("ROOT_DATAMODEL_ID")
			expect(#parentUid).to.equal(12)

			-- Verify child got uniqueId
			local childUid = UniqueIdHelpers.getUniqueId(childScript)
			expect(childUid).to.be.ok()
			expect(#childUid).to.equal(12)
		end)

		it("should generate different uniqueIds for different parents", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, { isService = true }, os.clock() * 1000)

			-- Create two parent folders WITHOUT uniqueIds
			local parent1 = Instance.new("Folder")
			parent1.Name = "Parent1"
			parent1.Parent = serverScriptService
			table.insert(createdInstances, parent1)
			tree:insertInstance(parent1, "TEMP00000001", {}, os.clock() * 1000)

			local parent2 = Instance.new("Folder")
			parent2.Name = "Parent2"
			parent2.Parent = serverScriptService
			table.insert(createdInstances, parent2)
			tree:insertInstance(parent2, "TEMP00000002", {}, os.clock() * 1000)

			-- Create children for each parent
			local child1 = Instance.new("ModuleScript")
			child1.Name = "Child1"
			child1.Parent = parent1
			table.insert(createdInstances, child1)

			local child2 = Instance.new("ModuleScript")
			child2.Name = "Child2"
			child2.Parent = parent2
			table.insert(createdInstances, child2)

			-- Process both children
			readProcessor:onAdd(child1)
			readProcessor:onAdd(child2)

			-- Verify both parents got unique IDs
			local parent1Uid = UniqueIdHelpers.getUniqueId(parent1)
			local parent2Uid = UniqueIdHelpers.getUniqueId(parent2)

			expect(parent1Uid).to.be.ok()
			expect(parent2Uid).to.be.ok()

			-- Verify IDs are different
			expect(parent1Uid).never.to.equal(parent2Uid)

			-- Verify both are valid
			expect(#parent1Uid).to.equal(12)
			expect(#parent2Uid).to.equal(12)
		end)
	end)

	describe("ReadProcessor.onChange - Parent Change (Move)", function()
		local Tree
		local ReadProcessor
		local UniqueIdHelpers
		local tree
		local readProcessor
		local workspace
		local createdInstances

		beforeAll(function()
			local Codex = script:FindFirstAncestor("Codex")
			Tree = require(Codex.Core.Tree)
			ReadProcessor = require(script.Parent.Read)
			UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

			workspace = game:GetService("Workspace")
		end)

		beforeEach(function()
			tree = Tree.new()
			readProcessor = ReadProcessor.new(tree)
			createdInstances = {}
		end)

		afterEach(function()
			-- Clean up test instances
			for _, instance in ipairs(createdInstances) do
				if instance and instance.Parent then
					instance:Destroy()
				end
			end
			createdInstances = {}
		end)

		it("should return move Change when Parent property changes", function()
			-- Register Workspace in tree as a service
			local wsId = "ws1"
			tree:insertInstance(workspace, wsId, { isService = true }, os.clock() * 1000)

			-- Create and register a Folder in Workspace
			local folder = Instance.new("Folder")
			folder.Name = "Folder"
			folder.Parent = workspace
			table.insert(createdInstances, folder)

			local folderId = "hAmHYdeWhAmH"
			UniqueIdHelpers.setUniqueId(folder, folderId)
			tree:insertInstance(folder, folderId, {}, os.clock() * 1000)

			-- Create a Part initially in Workspace
			local part = Instance.new("Part")
			part.Name = "Part"
			part.Parent = workspace
			table.insert(createdInstances, part)

			-- Set uniqueId and register in tree
			local partId = "qhIXfPxBqhIX"
			UniqueIdHelpers.setUniqueId(part, partId)
			tree:insertInstance(part, partId, {}, os.clock() * 1000)

			-- Capture old path and old parent ID BEFORE the move
			local oldPath = "Workspace/Part"
			local oldParentId = wsId

			-- NOW move the Part to Folder (this triggers Parent change)
			part.Parent = folder

			-- Call onChange with the captured old values
			local change = readProcessor:onChange(part, "Parent", oldPath, oldParentId)

			-- Assert the return value matches the log expectations
			expect(change).to.be.ok()
			expect(change.op).to.equal("move")
			expect(change.uniqueId).to.equal(partId)
			expect(change.name).to.equal("Part")

			-- Verify paths
			expect(change.oldPath).to.equal("Workspace/Part")
			expect(change.path).to.equal("Workspace/Folder/Part")

			-- Verify parent IDs
			expect(change.oldParentId).to.equal(wsId) -- "ws1"
			expect(change.parentId).to.equal(folderId) -- "hAmHYdeWhAmH"

			-- Verify source
			expect(change.source).to.equal("plugin")
		end)

		it("should return move Change when Name property changes (rename)", function()
			-- Register Workspace in tree
			local wsId = "ws1"
			tree:insertInstance(workspace, wsId, { isService = true }, os.clock() * 1000)

			-- Create a Part in Workspace
			local part = Instance.new("Part")
			part.Name = "OriginalName"
			part.Parent = workspace
			table.insert(createdInstances, part)

			-- Set uniqueId and register in tree
			local partId = "ABC123456789"
			UniqueIdHelpers.setUniqueId(part, partId)
			tree:insertInstance(part, partId, {}, os.clock() * 1000)

			-- Capture old path BEFORE rename
			local oldPath = "Workspace/OriginalName"

			-- NOW rename the Part
			part.Name = "NewName"

			-- Call onChange
			local change = readProcessor:onChange(part, "Name", oldPath, nil)

			-- Assert rename creates move Change
			expect(change).to.be.ok()
			expect(change.op).to.equal("move")
			expect(change.uniqueId).to.equal(partId)
			expect(change.name).to.equal("NewName")

			-- Verify paths
			expect(change.oldPath).to.equal("Workspace/OriginalName")
			expect(change.path).to.equal("Workspace/NewName")

			-- Verify parent IDs (same parent for rename)
			expect(change.oldParentId).to.equal(wsId)
			expect(change.parentId).to.equal(wsId)
		end)

		it("should return updateInstance Change for property changes", function()
			-- Register Workspace in tree
			local wsId = "ws1"
			tree:insertInstance(workspace, wsId, { isService = true }, os.clock() * 1000)

			-- Create a Part in Workspace
			local part = Instance.new("Part")
			part.Name = "TestPart"
			part.BrickColor = BrickColor.Red()
			part.Parent = workspace
			table.insert(createdInstances, part)

			-- Set uniqueId and register in tree
			local partId = "PART12345678"
			UniqueIdHelpers.setUniqueId(part, partId)
			tree:insertInstance(part, partId, {}, os.clock() * 1000)

			-- Change a property (not Parent or Name)
			part.BrickColor = BrickColor.Blue()

			-- Call onChange
			local change = readProcessor:onChange(part, "BrickColor", nil, nil)

			-- Assert updateInstance Change is returned
			expect(change).to.be.ok()
			expect(change.op).to.equal("updateInstance")
			expect(change.uniqueId).to.equal(partId)
			expect(change.path).to.equal("Workspace/TestPart")

			-- Verify properties field exists
			expect(change.properties).to.be.ok()
			expect(change.properties.BrickColor).to.be.ok()
		end)

		it("should return write Change for script Source changes", function()
			-- Register Workspace in tree
			local wsId = "ws1"
			tree:insertInstance(workspace, wsId, { isService = true }, os.clock() * 1000)

			-- Create a Script in Workspace
			local script = Instance.new("ModuleScript")
			script.Name = "TestScript"
			script.Source = "-- Original content"
			script.Parent = workspace
			table.insert(createdInstances, script)

			-- Set uniqueId and register in tree
			local scriptId = "SCRIPT123456"
			UniqueIdHelpers.setUniqueId(script, scriptId)
			tree:insertInstance(script, scriptId, {}, os.clock() * 1000)

			-- Change script source
			script.Source = "-- Modified content"

			-- Call onChange
			local change = readProcessor:onChange(script, "Source", nil, nil)

			-- Assert write Change is returned (update operation)
			expect(change).to.be.ok()
			expect(change.op).to.equal("write")
			expect(change.uniqueId).to.equal(scriptId)
			expect(change.content).to.equal("-- Modified content")
			expect(change.isNew).to.equal(false) -- update, not new
			expect(change.robloxClass).to.equal("ModuleScript")
		end)
	end)
end
