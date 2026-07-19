
-- Unit tests for Watcher.__tagInstance — duplicate uniqueId handling

return function()
	describe("Watcher.__tagInstance", function()
		local Tree
		local Watcher
		local UniqueIdHelpers
		local tree
		local watcher
		local workspace
		local createdInstances

		beforeAll(function()
			local Codex = script:FindFirstAncestor("Codex")
			Tree = require(Codex.Core.Tree)
			Watcher = require(Codex.Watcher)
			UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
			workspace = game:GetService("Workspace")
		end)

		beforeEach(function()
			tree = Tree.new()
			watcher = Watcher.new(tree)
			createdInstances = {}
		end)

		afterEach(function()
			for _, instance in ipairs(createdInstances) do
				if instance and instance.Parent then
					instance:Destroy()
				end
			end
			createdInstances = {}
		end)

		it("assigns a fresh uniqueId to an untagged instance", function()
			local part = Instance.new("Part")
			part.Name = "TestPart_FreshTag"
			part.Parent = workspace
			table.insert(createdInstances, part)

			watcher:__tagInstance(part)

			local id = UniqueIdHelpers.getUniqueId(part)
			expect(id).to.be.ok()
			expect(typeof(id)).to.equal("string")
			expect(tree:getInstance(id)).to.equal(part)
		end)

		it("preserves an existing uniqueId when no other instance claims it", function()
			local part = Instance.new("Part")
			part.Name = "TestPart_ExistingId"
			UniqueIdHelpers.setUniqueId(part, "PRESERVEDIDXX")
			part.Parent = workspace
			table.insert(createdInstances, part)

			-- Pre-register so the watcher sees this instance as the canonical owner.
			tree:insertInstance(part, "PRESERVEDIDXX", {})

			watcher:__tagInstance(part)

			expect(UniqueIdHelpers.getUniqueId(part)).to.equal("PRESERVEDIDXX")
			expect(tree:getInstance("PRESERVEDIDXX")).to.equal(part)
		end)

		it("regenerates the uniqueId when a duplicate carries a colliding id", function()
			-- Original part: tag it normally.
			local original = Instance.new("Part")
			original.Name = "TestPart_Original"
			original.Parent = workspace
			table.insert(createdInstances, original)
			watcher:__tagInstance(original)

			local originalId = UniqueIdHelpers.getUniqueId(original)
			expect(originalId).to.be.ok()

			-- Simulate Studio duplication: Clone copies all attributes, including
			-- CodexUniqueID. This is the exact path that produced the bug.
			local duplicate = original:Clone()
			duplicate.Name = "TestPart_Duplicate"
			duplicate.Parent = workspace
			table.insert(createdInstances, duplicate)

			expect(UniqueIdHelpers.getUniqueId(duplicate)).to.equal(originalId)

			watcher:__tagInstance(duplicate)

			local duplicateId = UniqueIdHelpers.getUniqueId(duplicate)
			expect(duplicateId).to.be.ok()
			expect(duplicateId).never.to.equal(originalId)

			-- Both instances should be queryable independently after the fix.
			expect(tree:getInstance(originalId)).to.equal(original)
			expect(tree:getInstance(duplicateId)).to.equal(duplicate)
		end)
	end)
end
