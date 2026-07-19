
-- Unit tests for AdditionProcessor based on real poll response data from debug/plugin-normal.log

return function()
	describe("AdditionProcessor.applyAddition - Real Poll Data Integration", function()
		local Tree
		local WriteProcessor
		local tree
		local writeProcessor
		local workspace
		local serverScriptService
		local createdInstances

		beforeAll(function()
			-- Load real modules using relative paths
			-- script is AdditionProcessor.spec.luau
			-- script.Parent is Write/
			-- script.Parent.Parent is Processor/
			-- script.Parent.Parent.Parent is Core/
			local Codex = script:FindFirstAncestor("Codex")
			Tree = require(Codex.Core.Tree)
			WriteProcessor = require(script.Parent)

			-- Use actual Roblox services
			workspace = game:GetService("Workspace")
			serverScriptService = game:GetService("ServerScriptService")
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

		it("should create a Part with properties (Platform1 from poll data)", function()
			-- Register Workspace in tree
			local ws1Id = "ws1"
			tree:insertInstance(workspace, ws1Id, {}, os.clock() * 1000)

			-- Real data from debug/plugin-normal.log lines 22-38
			local change = {
				op = "createInstance",
				path = "Workspace/Platform1",
				uniqueId = "UCPR5OIEQZRY",
				robloxClass = "Part",
				parentId = "ws1",
				source = "agent",
				ts = 1761025872560,
				properties = {
					Size = { 10, 1, 10 },
					Color = { 0, 170, 255 },
					Anchored = true,
					CFrame = {
						Position = { 0, 5, 10 },
					},
				},
			}

			local result = writeProcessor.additionProcessor:applyAddition(change)
			table.insert(createdInstances, result)

			-- Verify instance was created
			expect(result).to.be.ok()
			expect(result.ClassName).to.equal("Part")
			expect(result.Name).to.equal("Platform1")
			expect(result.Parent).to.equal(workspace)

			-- Verify properties were set (converted from array to Roblox types)
			expect(result.Size).to.equal(Vector3.new(10, 1, 10))
			expect(result.Anchored).to.equal(true)
			-- Color should be converted from [0, 170, 255] to Color3
			expect(result.Color.R).to.be.near(0, 0.01)
			expect(result.Color.G).to.be.near(0.666667, 0.01)
			expect(result.Color.B).to.be.near(1, 0.01)

			-- Verify uniqueId attribute was set (using CodexUniqueID)
			expect(result:GetAttribute("CodexUniqueID")).to.equal("UCPR5OIEQZRY")
			expect(result:GetAttribute("_serverCreated")).to.equal(true)

			-- Verify instance was registered in tree
			local uniqueId = "UCPR5OIEQZRY"
			local treeInstance = tree:getInstance(uniqueId)
			expect(treeInstance).to.equal(result)
		end)

		it("should create a Part with attributes (FinishZone from poll data)", function()
			-- Register Workspace in tree
			local ws1Id = "ws1"
			tree:insertInstance(workspace, ws1Id, {}, os.clock() * 1000)

			-- Real data from debug/plugin-normal.log lines 187-206
			local change = {
				op = "createInstance",
				path = "Workspace/FinishZone",
				uniqueId = "BEMSUWNAIROL",
				robloxClass = "Part",
				parentId = "ws1",
				source = "agent",
				ts = 1761025873169,
				attributes = {
					IsFinishZone = true,
				},
				properties = {
					Size = { 10, 10, 2 },
					Color = { 255, 215, 0 },
					Anchored = true,
					CFrame = {
						Position = { 0, 20, 35 },
					},
				},
			}

			local result = writeProcessor.additionProcessor:applyAddition(change)
			table.insert(createdInstances, result)

			-- Verify instance was created
			expect(result).to.be.ok()
			expect(result.ClassName).to.equal("Part")
			expect(result.Name).to.equal("FinishZone")
			expect(result.Parent).to.equal(workspace)

			-- Verify attributes were set
			expect(result:GetAttribute("IsFinishZone")).to.equal(true)
			expect(result:GetAttribute("CodexUniqueID")).to.equal("BEMSUWNAIROL")
			expect(result:GetAttribute("_serverCreated")).to.equal(true)

			-- Verify properties were set
			expect(result.Size).to.equal(Vector3.new(10, 10, 2))
			expect(result.Anchored).to.equal(true)
			-- Color should be converted from [255, 215, 0] to Color3 (normalized to 0-1 range)
			expect(result.Color.R).to.be.near(1, 0.01)
			expect(result.Color.G).to.be.near(0.843137, 0.01)
			expect(result.Color.B).to.be.near(0, 0.01)
		end)

		it("should create a Script with content (FinishDetector from poll data)", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, {}, os.clock() * 1000)

			-- Real data from debug/plugin-normal.log lines 302-358 (simplified content)
			local scriptContent = [[local finishZone = workspace:WaitForChild("FinishZone")

local playersWhoFinished = {}

finishZone.Touched:Connect(function(hit)
	local humanoid = hit.Parent:FindFirstChild("Humanoid")
	if humanoid then
		local player = game.Players:GetPlayerFromCharacter(hit.Parent)
		if player and not playersWhoFinished[player.UserId] then
			playersWhoFinished[player.UserId] = true
		end
	end
end)
]]

			local change = {
				op = "write",
				path = "ServerScriptService/FinishDetector",
				uniqueId = "HAC5JUE5N6DF",
				robloxClass = "Script",
				parentId = "sss",
				source = "agent",
				ts = 1761025897827,
				isNew = true,
				content = scriptContent,
			}

			local result = writeProcessor.additionProcessor:applyAddition(change)
			table.insert(createdInstances, result)

			-- Verify instance was created
			expect(result).to.be.ok()
			expect(result.ClassName).to.equal("Script")
			expect(result.Name).to.equal("FinishDetector")
			expect(result.Parent).to.equal(serverScriptService)

			-- Verify content was set
			expect(result.Source).to.equal(scriptContent)

			-- Verify uniqueId attribute was set (using CodexUniqueID)
			expect(result:GetAttribute("CodexUniqueID")).to.equal("HAC5JUE5N6DF")
			expect(result:GetAttribute("_serverCreated")).to.equal(true)

			-- Verify instance was registered in tree
			local uniqueId = "HAC5JUE5N6DF"
			local treeInstance = tree:getInstance(uniqueId)
			expect(treeInstance).to.equal(result)
		end)

		it("should deduplicate instances with same uniqueId and same path", function()
			-- Register Workspace in tree
			local ws1Id = "ws1"
			tree:insertInstance(workspace, ws1Id, {}, os.clock() * 1000)

			-- Create first instance
			local change1 = {
				op = "createInstance",
				path = "Workspace/DedupTestPart",
				uniqueId = "DEDUPTEST999",
				robloxClass = "Part",
				parentId = "ws1",
				properties = { Size = { 1, 1, 1 } },
			}

			local result1 = writeProcessor.additionProcessor:applyAddition(change1)
			table.insert(createdInstances, result1)

			expect(result1).to.be.ok()
			expect(result1.Name).to.equal("DedupTestPart")
			expect(result1.Size).to.equal(Vector3.new(1, 1, 1))

			-- Try to create again with same uniqueId and same path but different properties
			local change2 = {
				op = "createInstance",
				path = "Workspace/DedupTestPart", -- Same path
				uniqueId = "DEDUPTEST999", -- Same uniqueId
				robloxClass = "Part",
				parentId = "ws1",
				properties = { Size = { 5, 5, 5 } }, -- Different size
			}

			local result2 = writeProcessor.additionProcessor:applyAddition(change2)

			-- Should return the same instance (deduplication)
			expect(result2).to.equal(result1)

			-- Properties should be updated
			expect(result2.Size).to.equal(Vector3.new(5, 5, 5))

			-- Should only have ONE instance with this uniqueId
			local count = 0
			for _, child in ipairs(workspace:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "DEDUPTEST999" then
					count = count + 1
				end
			end
			expect(count).to.equal(1)
		end)

		it("should handle multiple instances created in sequence (TestBlock1, TestBlock2, TestBlock3)", function()
			-- Register Workspace in tree
			local ws1Id = "ws1"
			tree:insertInstance(workspace, ws1Id, {}, os.clock() * 1000)

			-- Use unique IDs that won't conflict with other tests
			-- Create TestBlock1
			local change1 = {
				op = "createInstance",
				path = "Workspace/TestBlock1",
				uniqueId = "TESTBLOCK001",
				robloxClass = "Part",
				parentId = "ws1",
				properties = { Size = { 10, 1, 10 } },
			}

			-- Create TestBlock2
			local change2 = {
				op = "createInstance",
				path = "Workspace/TestBlock2",
				uniqueId = "TESTBLOCK002",
				robloxClass = "Part",
				parentId = "ws1",
				properties = { Size = { 10, 1, 10 } },
			}

			-- Create TestBlock3
			local change3 = {
				op = "createInstance",
				path = "Workspace/TestBlock3",
				uniqueId = "TESTBLOCK003",
				robloxClass = "Part",
				parentId = "ws1",
				properties = { Size = { 10, 1, 10 } },
			}

			local result1 = writeProcessor.additionProcessor:applyAddition(change1)
			local result2 = writeProcessor.additionProcessor:applyAddition(change2)
			local result3 = writeProcessor.additionProcessor:applyAddition(change3)

			table.insert(createdInstances, result1)
			table.insert(createdInstances, result2)
			table.insert(createdInstances, result3)

			-- Verify all three instances were created
			expect(result1).to.be.ok()
			expect(result2).to.be.ok()
			expect(result3).to.be.ok()

			-- Verify they are distinct instances
			expect(result1).never.to.equal(result2)
			expect(result2).never.to.equal(result3)
			expect(result1).never.to.equal(result3)

			-- Verify names
			expect(result1.Name).to.equal("TestBlock1")
			expect(result2.Name).to.equal("TestBlock2")
			expect(result3.Name).to.equal("TestBlock3")

			-- Verify all three have different uniqueIds (using CodexUniqueID)
			expect(result1:GetAttribute("CodexUniqueID")).to.equal("TESTBLOCK001")
			expect(result2:GetAttribute("CodexUniqueID")).to.equal("TESTBLOCK002")
			expect(result3:GetAttribute("CodexUniqueID")).to.equal("TESTBLOCK003")

			-- Verify all three are in tree
			expect(tree:getInstance("TESTBLOCK001")).to.equal(result1)
			expect(tree:getInstance("TESTBLOCK002")).to.equal(result2)
			expect(tree:getInstance("TESTBLOCK003")).to.equal(result3)
		end)

		it("should apply second name when two consecutive writes with isNew flag have different names", function()
			-- Register ServerScriptService in tree
			local sssId = "sss"
			tree:insertInstance(serverScriptService, sssId, {}, os.clock() * 1000)

			-- First write with isNew=true and initial name
			local change1 = {
				op = "write",
				path = "ServerScriptService/InitialName",
				uniqueId = "RENAMETEST01",
				robloxClass = "Script",
				parentId = "sss",
				source = "agent",
				ts = 1761025897827,
				isNew = true,
				content = "print('Hello from first write')",
			}

			local result1 = writeProcessor.additionProcessor:applyAddition(change1)
			table.insert(createdInstances, result1)

			-- Verify first instance was created with initial name
			expect(result1).to.be.ok()
			expect(result1.Name).to.equal("InitialName")
			expect(result1.Source).to.equal("print('Hello from first write')")

			-- Second write with isNew=true but different name (simulating a rename before creation completes)
			local change2 = {
				op = "write",
				path = "ServerScriptService/FinalName",
				uniqueId = "RENAMETEST01", -- Same uniqueId
				robloxClass = "Script",
				parentId = "sss",
				source = "agent",
				ts = 1761025897828,
				isNew = true,
				content = "print('Hello from second write')",
			}

			local result2 = writeProcessor.additionProcessor:applyAddition(change2)

			-- Should return the same instance (deduplication by uniqueId)
			expect(result2).to.equal(result1)

			-- The final name should be from the second write
			expect(result2.Name).to.equal("FinalName")

			-- Content should also be updated
			expect(result2.Source).to.equal("print('Hello from second write')")

			-- Should only have ONE instance with this uniqueId
			local count = 0
			for _, child in ipairs(serverScriptService:GetChildren()) do
				if child:GetAttribute("CodexUniqueID") == "RENAMETEST01" then
					count = count + 1
				end
			end
			expect(count).to.equal(1)

			-- Verify it's still registered in tree with the same uniqueId
			local uniqueId = "RENAMETEST01"
			expect(tree:getInstance(uniqueId)).to.equal(result2)
		end)
	end)
end
