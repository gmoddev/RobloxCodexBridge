--!strict
-- Tree.spec.luau
-- Unit tests for Tree, focused on uniqueId resolution self-healing
-- (Phase 1: getInstance slow-path) and duplicate-id collision handling
-- (Phase 2: populateExistingInstances).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tree = require(script.Parent.Tree)
local UniqueIdHelpers = require(script.Parent.Parent.Util.UniqueIdHelpers)

return function()
	local tree: any
	local sandbox: Folder

	beforeEach(function()
		tree = Tree.new()
		-- Each test gets a fresh sandbox folder under ReplicatedStorage.
		-- ReplicatedStorage is one of the standard root services the
		-- slow-path attribute walk traverses, so anything here is
		-- reachable.
		sandbox = Instance.new("Folder")
		sandbox.Name = "TreeSpecSandbox"
		sandbox.Parent = ReplicatedStorage
	end)

	afterEach(function()
		if sandbox and sandbox.Parent then
			sandbox:Destroy()
		end
	end)

	describe("getInstance slow-path (Phase 1)", function()
		it("recovers an instance that has CodexUniqueID stamped but is not in instanceMap", function()
			local part = Instance.new("Part")
			part.Name = "Stranded"
			part.Parent = sandbox

			-- Simulate the divergence: attribute is stamped (so glob can
			-- see it), but Tree was never told about it (so instanceMap
			-- has no entry — duplicate-id collision dropped during
			-- populate, missed Watcher event, etc.).
			UniqueIdHelpers.setUniqueId(part, "TestStrandedId123")
			expect(tree.instanceMap["TestStrandedId123"]).never.to.be.ok()

			local result = tree:getInstance("TestStrandedId123")

			expect(result).to.equal(part)
			-- And the slow-path should self-register so subsequent reads
			-- hit the fast path.
			expect(tree.instanceMap["TestStrandedId123"]).to.equal(part)
		end)

		it("returns nil for a uniqueId no live instance has stamped", function()
			local result = tree:getInstance("NoSuchIdAtAll999")
			expect(result).never.to.be.ok()
		end)

		it("does not call attribute walk when fast-path hits", function()
			local part = Instance.new("Part")
			part.Name = "FastPath"
			part.Parent = sandbox

			tree:insertInstance(part, "FastPathId456", {})

			-- Spy on _findInstanceByAttributeWalk by replacing it.
			local walkCallCount = 0
			local realWalk = tree._findInstanceByAttributeWalk
			tree._findInstanceByAttributeWalk = function(self, id)
				walkCallCount += 1
				return realWalk(self, id)
			end

			local result = tree:getInstance("FastPathId456")

			expect(result).to.equal(part)
			expect(walkCallCount).to.equal(0)
		end)
	end)

	describe("populateExistingInstances duplicate-id collision (Phase 2)", function()
		it("re-stamps the second instance when two share the same CodexUniqueID", function()
			local first = Instance.new("Part")
			first.Name = "First"
			first.Parent = sandbox
			UniqueIdHelpers.setUniqueId(first, "DupCollisionId789")

			local second = Instance.new("Part")
			second.Name = "Second"
			second.Parent = sandbox
			UniqueIdHelpers.setUniqueId(second, "DupCollisionId789")

			-- Run population over our sandbox.
			tree:populateExistingInstances({ sandbox })

			-- The first instance keeps the original id.
			expect(tree:getInstance("DupCollisionId789")).to.equal(first)
			expect(UniqueIdHelpers.getUniqueId(first)).to.equal("DupCollisionId789")

			-- The second instance got a fresh id, is registered under
			-- it, and that id is different from the original.
			local secondNewId = UniqueIdHelpers.getUniqueId(second)
			expect(secondNewId).to.be.ok()
			expect(secondNewId).never.to.equal("DupCollisionId789")
			expect(tree:getInstance(secondNewId :: string)).to.equal(second)
		end)

		it("is a no-op when an instance is already correctly registered", function()
			local part = Instance.new("Part")
			part.Name = "AlreadyRegistered"
			part.Parent = sandbox
			UniqueIdHelpers.setUniqueId(part, "AlreadyRegisteredId")

			-- Pre-register it; populate should leave it alone.
			tree:insertInstance(part, "AlreadyRegisteredId", {})

			tree:populateExistingInstances({ sandbox })

			expect(tree:getInstance("AlreadyRegisteredId")).to.equal(part)
			expect(UniqueIdHelpers.getUniqueId(part)).to.equal("AlreadyRegisteredId")
		end)

		it("assigns a fresh id to instances without one", function()
			local part = Instance.new("Part")
			part.Name = "Untagged"
			part.Parent = sandbox
			expect(UniqueIdHelpers.getUniqueId(part)).never.to.be.ok()

			tree:populateExistingInstances({ sandbox })

			local newId = UniqueIdHelpers.getUniqueId(part)
			expect(newId).to.be.ok()
			expect(tree:getInstance(newId :: string)).to.equal(part)
		end)
	end)
end
