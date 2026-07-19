--!strict
-- grepUtils.spec.luau
-- Unit tests for grep utility functions, focusing on extractContext and contextLines param

local grepUtils = require(script.Parent.grepUtils)

return function()
	describe("extractContext", function()
		-- Helper to build lineOffsets from a source string (same logic as searchPlainText)
		local function buildLineOffsets(source: string): { number }
			local lineOffsets: { number } = { 1 }
			for i = 1, #source do
				if source:sub(i, i) == "\n" then
					table.insert(lineOffsets, i + 1)
				end
			end
			return lineOffsets
		end

		it("should return context lines before and after a match", function()
			local source = "line1\nline2\nline3\nline4\nline5"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 3, 2)

			expect(before).to.equal("line1\nline2")
			expect(after).to.equal("line4\nline5")
		end)

		it("should return nil for both when contextLines is 0", function()
			local source = "line1\nline2\nline3"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 2, 0)

			expect(before).never.to.be.ok()
			expect(after).never.to.be.ok()
		end)

		it("should handle match on first line (no contextBefore)", function()
			local source = "first\nsecond\nthird"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 1, 2)

			expect(before).never.to.be.ok()
			expect(after).to.equal("second\nthird")
		end)

		it("should handle match on last line (no contextAfter)", function()
			local source = "first\nsecond\nthird"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 3, 2)

			expect(before).to.equal("first\nsecond")
			expect(after).never.to.be.ok()
		end)

		it("should clamp context to available lines", function()
			-- Request 10 context lines but only 2 available on each side
			local source = "a\nb\nMATCH\nd\ne"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 3, 10)

			expect(before).to.equal("a\nb")
			expect(after).to.equal("d\ne")
		end)

		it("should return single line of context when contextLines is 1", function()
			local source = "line1\nline2\nline3\nline4\nline5"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 3, 1)

			expect(before).to.equal("line2")
			expect(after).to.equal("line4")
		end)

		it("should handle single-line source", function()
			local source = "only line"
			local offsets = buildLineOffsets(source)

			local before, after = grepUtils.extractContext(source, offsets, 1, 3)

			expect(before).never.to.be.ok()
			expect(after).never.to.be.ok()
		end)
	end)

	describe("searchPlainText with contextLines", function()
		it("should include context in match results", function()
			local source = "aaa\nbbb\nfindme\nccc\nddd"
			local matches = grepUtils.searchPlainText(source, "findme", false, 5, 2)

			expect(#matches).to.equal(1)
			expect(matches[1].lineNumber).to.equal(3)
			expect(matches[1].matchText).to.equal("findme")
			expect(matches[1].contextBefore).to.equal("aaa\nbbb")
			expect(matches[1].contextAfter).to.equal("ccc\nddd")
		end)

		it("should have no context when contextLines is 0", function()
			local source = "aaa\nbbb\nfindme\nccc\nddd"
			local matches = grepUtils.searchPlainText(source, "findme", false, 5, 0)

			expect(#matches).to.equal(1)
			expect(matches[1].contextBefore).never.to.be.ok()
			expect(matches[1].contextAfter).never.to.be.ok()
		end)

		it("should have no context when contextLines is nil (backward compat)", function()
			local source = "aaa\nbbb\nfindme\nccc\nddd"
			local matches = grepUtils.searchPlainText(source, "findme", false, 5, nil)

			expect(#matches).to.equal(1)
			-- nil contextLines should result in no context (nil check in implementation)
			expect(matches[1].contextBefore).never.to.be.ok()
			expect(matches[1].contextAfter).never.to.be.ok()
		end)
	end)

	describe("searchPattern with contextLines", function()
		it("should include context in pattern match results", function()
			local source = "aaa\nbbb\nfind123me\nccc\nddd"
			local matches = grepUtils.searchPattern(source, "find%d+me", false, 5, 1)

			expect(#matches).to.equal(1)
			expect(matches[1].lineNumber).to.equal(3)
			expect(matches[1].matchText).to.equal("find123me")
			expect(matches[1].contextBefore).to.equal("bbb")
			expect(matches[1].contextAfter).to.equal("ccc")
		end)
	end)

	describe("search with contextLines", function()
		it("should pass contextLines through to search functions", function()
			-- Create a test script
			local script = Instance.new("Script")
			script.Name = "SearchContextTest"
			script.Source = "line1\nline2\ntarget\nline4\nline5"
			script.Parent = game:GetService("ServerScriptService")

			local matches = grepUtils.search(script, "target", false, false, 5, 2)

			expect(matches).to.be.ok()
			expect(#matches).to.equal(1)
			expect(matches[1].contextBefore).to.equal("line1\nline2")
			expect(matches[1].contextAfter).to.equal("line4\nline5")

			-- Cleanup
			script:Destroy()
		end)
	end)
end
