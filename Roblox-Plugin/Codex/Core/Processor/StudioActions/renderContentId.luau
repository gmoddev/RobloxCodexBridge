
-- renderContentId: Render a Roblox `rbxtemp://` (or other resolvable) content ID
-- to a base64-encoded RGBA buffer using EditableImage.
--
-- Lifted from captureScreenshot.luau so both the live screenshot path and the
-- playtest frame-capture path share the same encoder. The render is identical
-- for both: ReadPixelsBuffer has a 1024-per-dimension limit, so we tile when
-- needed.

local AssetService = game:GetService("AssetService")

local renderContentId = {}

-- Base64 encoding (no built-in base64 in Roblox)
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function renderContentId.base64encode(buf: buffer): string
	local parts = {}
	local len = buffer.len(buf)
	for i = 0, len - 1, 3 do
		local b1 = buffer.readu8(buf, i)
		local b2 = i + 1 < len and buffer.readu8(buf, i + 1) or 0
		local b3 = i + 2 < len and buffer.readu8(buf, i + 2) or 0
		local n = b1 * 65536 + b2 * 256 + b3
		parts[#parts + 1] = string.sub(b64chars, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
		parts[#parts + 1] = string.sub(b64chars, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
		parts[#parts + 1] = i + 1 < len
				and string.sub(b64chars, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
			or "="
		parts[#parts + 1] = i + 2 < len and string.sub(b64chars, n % 64 + 1, n % 64 + 1) or "="
	end
	return table.concat(parts)
end

local TILE_MAX = 1024

export type RenderResult = {
	width: number,
	height: number,
	data: string?,
	tiles: {
		{
			x: number,
			y: number,
			width: number,
			height: number,
			data: string,
		}
	}?,
}

export type RenderBufferResult = {
	width: number,
	height: number,
	rawBuffer: buffer,
}

-- Render a content ID to a base64-encoded RGBA result.
-- Returns single-tile `{ width, height, data }` when `outW <= 1024 and outH <= 1024`,
-- otherwise tiled `{ width, height, tiles }`. Throws inside the caller's pcall on
-- EditableImage / ReadPixelsBuffer failure.
function renderContentId.render(contentId: string, maxWidth: number): RenderResult
	local srcImg = AssetService:CreateEditableImageAsync(contentId)
	local srcSize = srcImg.Size

	local outW = math.min(maxWidth, srcSize.X)
	local outH = math.floor(outW * srcSize.Y / srcSize.X)
	local scaleX = outW / srcSize.X
	local scaleY = outH / srcSize.Y

	if outW <= TILE_MAX and outH <= TILE_MAX then
		if outW == srcSize.X and outH == srcSize.Y then
			local pixels = srcImg:ReadPixelsBuffer(Vector2.new(0, 0), srcSize)
			local b64 = renderContentId.base64encode(pixels)
			srcImg:Destroy()
			return { width = outW, height = outH, data = b64 }
		end
		local thumbImg = AssetService:CreateEditableImage({ Size = Vector2.new(outW, outH) })
		thumbImg:DrawImageTransformed(Vector2.new(outW / 2, outH / 2), Vector2.new(scaleX, scaleY), 0, srcImg)
		local pixels = thumbImg:ReadPixelsBuffer(Vector2.new(0, 0), Vector2.new(outW, outH))
		local b64 = renderContentId.base64encode(pixels)
		srcImg:Destroy()
		thumbImg:Destroy()
		return { width = outW, height = outH, data = b64 }
	end

	local tilesX = math.ceil(outW / TILE_MAX)
	local tilesY = math.ceil(outH / TILE_MAX)
	local tiles = {}

	for ty = 0, tilesY - 1 do
		for tx = 0, tilesX - 1 do
			local tileX = tx * TILE_MAX
			local tileY = ty * TILE_MAX
			local tileW = math.min(TILE_MAX, outW - tileX)
			local tileH = math.min(TILE_MAX, outH - tileY)

			local tileImg = AssetService:CreateEditableImage({
				Size = Vector2.new(tileW, tileH),
			})
			local posX = (outW / 2) - tileX
			local posY = (outH / 2) - tileY
			tileImg:DrawImageTransformed(Vector2.new(posX, posY), Vector2.new(scaleX, scaleY), 0, srcImg)
			local readOk, pixels =
				pcall(tileImg.ReadPixelsBuffer, tileImg, Vector2.new(0, 0), Vector2.new(tileW, tileH))
			if not readOk or not pixels then
				tileImg:Destroy()
				srcImg:Destroy()
				error(
					string.format(
						"ReadPixelsBuffer failed for tile (%d,%d) size %dx%d: %s",
						tileX,
						tileY,
						tileW,
						tileH,
						tostring(pixels)
					)
				)
			end
			table.insert(tiles, {
				x = tileX,
				y = tileY,
				width = tileW,
				height = tileH,
				data = renderContentId.base64encode(pixels),
			})
			tileImg:Destroy()
		end
	end

	srcImg:Destroy()
	return { width = outW, height = outH, tiles = tiles }
end

-- Render a content ID to a raw RGBA `buffer` (no base64). Single-tile only:
-- the upload path emits one storageId per frame, so multi-tile (outW or outH
-- > 1024) is unsupported here and errors. Callers must keep `maxWidth` ≤ 1024.
function renderContentId.renderToBuffer(contentId: string, maxWidth: number): RenderBufferResult
	local srcImg = AssetService:CreateEditableImageAsync(contentId)
	local srcSize = srcImg.Size

	local outW = math.min(maxWidth, srcSize.X)
	local outH = math.floor(outW * srcSize.Y / srcSize.X)

	if outW > TILE_MAX or outH > TILE_MAX then
		srcImg:Destroy()
		error(
			string.format(
				"renderToBuffer: multi-tile (>%d) not supported in upload mode; got %dx%d",
				TILE_MAX,
				outW,
				outH
			)
		)
	end

	local pixels: buffer
	if outW == srcSize.X and outH == srcSize.Y then
		pixels = srcImg:ReadPixelsBuffer(Vector2.new(0, 0), srcSize)
		srcImg:Destroy()
	else
		local scaleX = outW / srcSize.X
		local scaleY = outH / srcSize.Y
		local thumbImg = AssetService:CreateEditableImage({ Size = Vector2.new(outW, outH) })
		thumbImg:DrawImageTransformed(Vector2.new(outW / 2, outH / 2), Vector2.new(scaleX, scaleY), 0, srcImg)
		pixels = thumbImg:ReadPixelsBuffer(Vector2.new(0, 0), Vector2.new(outW, outH))
		srcImg:Destroy()
		thumbImg:Destroy()
	end

	return { width = outW, height = outH, rawBuffer = pixels }
end

return renderContentId
