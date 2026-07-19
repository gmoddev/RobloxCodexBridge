--!strict
-- Grep utilities for searching script content
-- Optimized: Lowercase once, configurable maxMatchesPerScript, quick contains check

local ScriptEditorService = game:GetService("ScriptEditorService")

local grepUtils = {}

-- Get script source code (try ScriptEditorService first, fallback to .Source)
function grepUtils.getScriptSource(script: LuaSourceContainer): string?
	-- Try ScriptEditorService first (more reliable)
	local success, document = pcall(function()
		return ScriptEditorService:FindScriptDocument(script)
	end)

	if success and document then
		local sourceSuccess, source = pcall(function()
			return document:GetText()
		end)
		if sourceSuccess and source then
			return source
		end
	end

	-- Fallback to .Source property
	local sourceSuccess, source = pcall(function()
		return script.Source
	end)

	if sourceSuccess and source then
		return source
	end

	return nil
end

-- Search result type
export type SearchMatch = {
	lineNumber: number,
	matchText: string,
	columnStart: number?,
	columnEnd: number?,
	contextBefore: string?,
	contextAfter: string?,
}

-- Default max matches per script (low for MCP/agent use)
local DEFAULT_MAX_MATCHES_PER_SCRIPT = 5

-- Quick check if source contains query (for early filtering)
function grepUtils.containsQuery(source: string, query: string, isPattern: boolean?, ignoreCase: boolean?): boolean
	local searchSource = source
	local searchQuery = query

	if ignoreCase then
		searchSource = searchSource:lower()
		searchQuery = searchQuery:lower()
	end

	if isPattern then
		local success, result = pcall(function()
			return searchSource:find(searchQuery) ~= nil
		end)
		return success and result
	else
		return searchSource:find(searchQuery, 1, true) ~= nil
	end
end

-- Extract context lines before/after a match using pre-built lineOffsets
function grepUtils.extractContext(
	source: string,
	lineOffsets: { number },
	lineNumber: number,
	contextLines: number
): (string?, string?)
	if contextLines <= 0 then
		return nil, nil
	end

	local totalLines = #lineOffsets

	-- Extract context before
	local beforeLines: { string } = {}
	local startLine = math.max(1, lineNumber - contextLines)
	for i = startLine, lineNumber - 1 do
		local lineStart = lineOffsets[i]
		local lineEnd = (lineOffsets[i + 1] or (#source + 2)) - 2
		table.insert(beforeLines, source:sub(lineStart, lineEnd))
	end

	-- Extract context after
	local afterLines: { string } = {}
	local endLine = math.min(totalLines, lineNumber + contextLines)
	for i = lineNumber + 1, endLine do
		local lineStart = lineOffsets[i]
		local lineEnd = (lineOffsets[i + 1] or (#source + 2)) - 2
		table.insert(afterLines, source:sub(lineStart, lineEnd))
	end

	local contextBefore = #beforeLines > 0 and table.concat(beforeLines, "\n") or nil
	local contextAfter = #afterLines > 0 and table.concat(afterLines, "\n") or nil

	return contextBefore, contextAfter
end

-- Plain text search (fast, case-sensitive or case-insensitive)
-- Optimized: Lowercase entire source once, not per-line
function grepUtils.searchPlainText(
	source: string,
	query: string,
	ignoreCase: boolean?,
	maxMatchesPerScript: number?,
	contextLines: number?
): { SearchMatch }
	local matches: { SearchMatch } = {}
	local maxMatches = maxMatchesPerScript or DEFAULT_MAX_MATCHES_PER_SCRIPT

	-- Lowercase entire source and query once (not per-line)
	local searchSource = ignoreCase and source:lower() or source
	local searchQuery = ignoreCase and query:lower() or query

	-- Build line offset table for O(1) line number lookup
	local lineOffsets: { number } = { 1 } -- Line 1 starts at offset 1
	for i = 1, #source do
		if source:sub(i, i) == "\n" then
			table.insert(lineOffsets, i + 1)
		end
	end

	-- Find all matches in the lowercased source
	local startPos = 1
	while #matches < maxMatches do
		local matchStart, matchEnd = searchSource:find(searchQuery, startPos, true)
		if not matchStart then
			break
		end

		-- Binary search for line number
		local lineNumber = 1
		local lo, hi = 1, #lineOffsets
		while lo <= hi do
			local mid = math.floor((lo + hi) / 2)
			if lineOffsets[mid] <= matchStart then
				lineNumber = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end

		-- Extract the original line (not lowercased) for display
		local lineStart = lineOffsets[lineNumber]
		local lineEnd = (lineOffsets[lineNumber + 1] or (#source + 2)) - 2 -- -2 to exclude \n
		local originalLine = source:sub(lineStart, lineEnd)

		local contextBefore, contextAfter = nil, nil
		if contextLines and contextLines > 0 then
			contextBefore, contextAfter = grepUtils.extractContext(source, lineOffsets, lineNumber, contextLines)
		end

		table.insert(matches, {
			lineNumber = lineNumber,
			matchText = originalLine,
			columnStart = matchStart - lineStart + 1,
			columnEnd = matchEnd - lineStart + 1,
			contextBefore = contextBefore,
			contextAfter = contextAfter,
		})

		startPos = matchEnd + 1
	end

	return matches
end

-- Lua pattern search (slower but more powerful)
-- Optimized: Lowercase entire source once
function grepUtils.searchPattern(
	source: string,
	pattern: string,
	ignoreCase: boolean?,
	maxMatchesPerScript: number?,
	contextLines: number?
): { SearchMatch }
	local matches: { SearchMatch } = {}
	local maxMatches = maxMatchesPerScript or DEFAULT_MAX_MATCHES_PER_SCRIPT

	-- Lowercase entire source and pattern once
	local searchSource = ignoreCase and source:lower() or source
	local searchPattern = ignoreCase and pattern:lower() or pattern

	-- Build line offset table for O(1) line number lookup
	local lineOffsets: { number } = { 1 }
	for i = 1, #source do
		if source:sub(i, i) == "\n" then
			table.insert(lineOffsets, i + 1)
		end
	end

	-- Find all pattern matches
	local startPos = 1
	while #matches < maxMatches and startPos <= #searchSource do
		local matchStart, matchEnd = searchSource:find(searchPattern, startPos)
		if not matchStart then
			break
		end

		-- Binary search for line number
		local lineNumber = 1
		local lo, hi = 1, #lineOffsets
		while lo <= hi do
			local mid = math.floor((lo + hi) / 2)
			if lineOffsets[mid] <= matchStart then
				lineNumber = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end

		-- Extract the original line for display
		local lineStart = lineOffsets[lineNumber]
		local lineEnd = (lineOffsets[lineNumber + 1] or (#source + 2)) - 2
		local originalLine = source:sub(lineStart, lineEnd)

		local contextBefore, contextAfter = nil, nil
		if contextLines and contextLines > 0 then
			contextBefore, contextAfter = grepUtils.extractContext(source, lineOffsets, lineNumber, contextLines)
		end

		table.insert(matches, {
			lineNumber = lineNumber,
			matchText = originalLine,
			columnStart = matchStart - lineStart + 1,
			columnEnd = matchEnd - lineStart + 1,
			contextBefore = contextBefore,
			contextAfter = contextAfter,
		})

		-- Advance by at least 1 to prevent infinite loop on zero-width matches
		startPos = math.max(matchEnd + 1, startPos + 1)
	end

	return matches
end

-- Main search function that routes to appropriate search method
function grepUtils.search(
	script: LuaSourceContainer,
	query: string,
	isPattern: boolean?,
	ignoreCase: boolean?,
	maxMatchesPerScript: number?,
	contextLines: number?
): { SearchMatch }?
	local source = grepUtils.getScriptSource(script)
	if not source then
		return nil
	end

	if isPattern then
		return grepUtils.searchPattern(source, query, ignoreCase, maxMatchesPerScript, contextLines)
	else
		return grepUtils.searchPlainText(source, query, ignoreCase, maxMatchesPerScript, contextLines)
	end
end

return grepUtils
