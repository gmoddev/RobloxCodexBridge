--!strict
-- patternUtils.spec.luau
-- Unit tests for glob pattern matching utilities
-- Tests define CORRECT behavior — some will FAIL against the current implementation
-- to catch known bugs (Bug 1: **/ServiceName/** and Bug 2: shorthand service paths)

local patternUtils = require(script.Parent.patternUtils)

return function()
	describe("globToLuaPattern", function()
		it("should convert simple wildcard *", function()
			local result = patternUtils.globToLuaPattern("ServerScriptService/*")
			-- * matches any characters except /
			expect(result).to.equal("^ServerScriptService/[^/]*$")
		end)

		it("should convert recursive wildcard **", function()
			local result = patternUtils.globToLuaPattern("ServerScriptService/**")
			-- ** matches any characters including /
			expect(result).to.equal("^ServerScriptService/.-$")
		end)

		it("should convert ? to single character", function()
			local result = patternUtils.globToLuaPattern("Script?")
			expect(result).to.equal("^Script[^/]$")
		end)

		it("should anchor pattern with ^ and $", function()
			local result = patternUtils.globToLuaPattern("test")
			expect(result).to.equal("^test$")
		end)

		it("should escape dots in pattern", function()
			local result = patternUtils.globToLuaPattern("file.lua")
			expect(result).to.equal("^file%.lua$")
		end)
	end)

	describe("matchGlob", function()
		it("should match exact name", function()
			expect(patternUtils.matchGlob("GameManager", "GameManager")).to.equal(true)
		end)

		it("should not match partial name without wildcard", function()
			expect(patternUtils.matchGlob("GameManagerExtra", "GameManager")).to.equal(false)
		end)

		it("should match with * wildcard", function()
			expect(patternUtils.matchGlob("GameManager", "*Manager")).to.equal(true)
			expect(patternUtils.matchGlob("GameManager", "Game*")).to.equal(true)
			expect(patternUtils.matchGlob("GameManager", "*Game*")).to.equal(true)
		end)

		it("should not match * across path separators", function()
			expect(patternUtils.matchGlob("ServerScriptService/GameManager", "*GameManager")).to.equal(false)
		end)

		it("should match ** across path separators", function()
			expect(patternUtils.matchGlob("ServerScriptService/GameManager", "**GameManager")).to.equal(true)
		end)

		it("should match with ? wildcard", function()
			expect(patternUtils.matchGlob("Script1", "Script?")).to.equal(true)
			expect(patternUtils.matchGlob("ScriptAB", "Script?")).to.equal(false)
		end)
	end)

	describe("matchPath - basic patterns", function()
		it("should match exact full path", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "ServerScriptService/GameManager")).to.equal(true)
		end)

		it("should match name-only pattern against full path", function()
			-- When pattern has no /, it should match just the instance name
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "GameManager")).to.equal(true)
		end)

		it("should match wildcard name pattern", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "*Manager")).to.equal(true)
		end)

		it("should match ** name search pattern", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "**/*Manager")).to.equal(true)
			expect(patternUtils.matchPath("ServerScriptService/Utils/GameManager", "**/*Manager")).to.equal(true)
		end)

		it("should match service/** pattern for direct children", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "ServerScriptService/**")).to.equal(true)
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "ServerScriptService/*")).to.equal(true)
		end)

		it("should match service/** pattern for nested children", function()
			expect(patternUtils.matchPath("ReplicatedStorage/Events/PlayerReady", "ReplicatedStorage/**")).to.equal(true)
		end)

		it("should match service/* pattern only for direct children", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "ServerScriptService/*")).to.equal(true)
			-- * should NOT match across path separators
			expect(patternUtils.matchPath("ServerScriptService/Utils/GameManager", "ServerScriptService/*")).to.equal(false)
		end)

		it("should not match wrong service", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "ReplicatedStorage/*")).to.equal(false)
		end)
	end)

	-- ============================================================
	-- Bug 1: **/ServiceName/** returns empty
	-- Pattern like **/ServerScriptService/** should match all
	-- descendants under ServerScriptService, but currently fails
	-- because the Lua pattern requires a / before the service name
	-- that doesn't exist at the root level.
	-- ============================================================
	describe("matchPath - Bug 1: **/ServiceName/** patterns", function()
		it("should match **/ServerScriptService/** for descendants", function()
			-- Path: ServerScriptService/GameManager
			-- Pattern: **/ServerScriptService/**
			-- The ** before ServiceName should match zero-length at root
			expect(patternUtils.matchPath(
				"ServerScriptService/GameManager",
				"**/ServerScriptService/**"
			)).to.equal(true)
		end)

		it("should match **/StarterPlayer/** for descendants", function()
			expect(patternUtils.matchPath(
				"StarterPlayer/StarterPlayerScripts/PlayerController",
				"**/StarterPlayer/**"
			)).to.equal(true)
		end)

		it("should match **/ReplicatedStorage/** for descendants", function()
			expect(patternUtils.matchPath(
				"ReplicatedStorage/Events/PlayerReady",
				"**/ReplicatedStorage/**"
			)).to.equal(true)
		end)

		it("should match **/ReplicatedStorage/** for direct children", function()
			expect(patternUtils.matchPath(
				"ReplicatedStorage/SharedConfig",
				"**/ReplicatedStorage/**"
			)).to.equal(true)
		end)

		it("should match **/StarterGui/** for nested UI hierarchy", function()
			expect(patternUtils.matchPath(
				"StarterGui/MainMenu/MenuFrame/PlayButton",
				"**/StarterGui/**"
			)).to.equal(true)
		end)

		it("should match **/ServerScriptService/** for deeply nested items", function()
			expect(patternUtils.matchPath(
				"ServerScriptService/Modules/Utils/Helper",
				"**/ServerScriptService/**"
			)).to.equal(true)
		end)

		it("should NOT match **/ServerScriptService/** for other services", function()
			expect(patternUtils.matchPath(
				"ReplicatedStorage/SharedConfig",
				"**/ServerScriptService/**"
			)).to.equal(false)
		end)
	end)

	-- ============================================================
	-- Bug 2: Shorthand service sub-paths fail
	-- StarterPlayerScripts/* should match items under
	-- StarterPlayer/StarterPlayerScripts/, but currently fails
	-- because the full path includes the parent service.
	-- ============================================================
	describe("matchPath - Bug 2: shorthand service sub-paths", function()
		it("should match StarterPlayerScripts/* as shorthand", function()
			-- Full path is StarterPlayer/StarterPlayerScripts/PlayerController
			-- but model commonly uses StarterPlayerScripts/* as a shorthand
			expect(patternUtils.matchPath(
				"StarterPlayer/StarterPlayerScripts/PlayerController",
				"StarterPlayerScripts/*"
			)).to.equal(true)
		end)

		it("should match StarterPlayerScripts/** for nested items", function()
			expect(patternUtils.matchPath(
				"StarterPlayer/StarterPlayerScripts/UI/HUD",
				"StarterPlayerScripts/**"
			)).to.equal(true)
		end)

		it("should match StarterCharacterScripts/* as shorthand", function()
			expect(patternUtils.matchPath(
				"StarterPlayer/StarterCharacterScripts/Animate",
				"StarterCharacterScripts/*"
			)).to.equal(true)
		end)

		it("should still match full path when provided", function()
			-- Full path should always work
			expect(patternUtils.matchPath(
				"StarterPlayer/StarterPlayerScripts/PlayerController",
				"StarterPlayer/StarterPlayerScripts/*"
			)).to.equal(true)
		end)
	end)

	-- ============================================================
	-- Edge cases: quotes in patterns, case sensitivity
	-- ============================================================
	describe("matchPath - edge cases", function()
		it("should match names with spaces", function()
			expect(patternUtils.matchPath("StarterGui/Your plot", "**/Your plot")).to.equal(true)
		end)

		it("should match wildcard search for names with spaces", function()
			-- matchPath is case-sensitive; glob.luau handles case-insensitive lowercasing
			-- The pattern **/*Your plot* matches the last segment, so it must match "Your plot" exactly
			expect(patternUtils.matchPath("StarterGui/Your plot", "**/*Your plot*")).to.equal(true)
			expect(patternUtils.matchPath("StarterGui/Your plot", "**/*plot*")).to.equal(true)
		end)

		it("should match names with hyphens", function()
			expect(patternUtils.matchPath(
				"ReplicatedStorage/UI/PlayerHUD-PopUp/Settings-PopUp",
				"**/Settings-PopUp"
			)).to.equal(true)
		end)

		it("should match exact non-wildcard name against any depth", function()
			-- Pattern without wildcards or / should match instance name at any depth
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "GameManager")).to.equal(true)
			expect(patternUtils.matchPath("ServerScriptService/Utils/GameManager", "GameManager")).to.equal(true)
		end)

		it("should match service root name itself", function()
			-- Matching the service itself (e.g., pattern "ServerScriptService")
			expect(patternUtils.matchPath("ServerScriptService", "ServerScriptService")).to.equal(true)
		end)

		it("should match partial name with ** prefix", function()
			expect(patternUtils.matchPath(
				"ReplicatedStorage/Events/PlayerReady",
				"**/Player*"
			)).to.equal(true)
		end)

		it("should not match when pattern is completely wrong", function()
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "Nonexistent")).to.equal(false)
			expect(patternUtils.matchPath("ServerScriptService/GameManager", "**/Nonexistent/**")).to.equal(false)
		end)
	end)

	-- ============================================================
	-- matchName tests
	-- ============================================================
	describe("matchName", function()
		it("should match exact name", function()
			expect(patternUtils.matchName("GameManager", "GameManager")).to.equal(true)
		end)

		it("should match with wildcard", function()
			expect(patternUtils.matchName("GameManager", "*Manager")).to.equal(true)
		end)

		it("should match case-insensitively when ignoreCase is true", function()
			expect(patternUtils.matchName("GameManager", "gamemanager", true)).to.equal(true)
			expect(patternUtils.matchName("OldShop", "oldshop", true)).to.equal(true)
		end)

		it("should not match case-insensitively by default", function()
			expect(patternUtils.matchName("GameManager", "gamemanager")).to.equal(false)
		end)
	end)
end
