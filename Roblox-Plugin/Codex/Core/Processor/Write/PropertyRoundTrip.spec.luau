--!strict
-- Integration tests for PropertySerializer and PropertyConverter round-trip compatibility
-- Tests that values serialized by PropertySerializer can be correctly deserialized by PropertyConverter

return function()
	local PropertySerializer = require(script.Parent.Parent.Parent.Parent.Util.PropertySerializer)
	local PropertyConverter = require(script.Parent.PropertyConverter)

	describe("PropertySerializer ↔ PropertyConverter Round-Trip", function()
		describe("Color3", function()
			it("should round-trip RGB color values", function()
				local part = Instance.new("Part")
				local originalColor = Color3.fromRGB(164, 189, 71)
				part.Color = originalColor

				-- Studio → Server (PropertySerializer)
				local serialized = PropertySerializer.serializePropertyValue("Color", part, originalColor)

				-- Verify serialized format: [R, G, B] in 0-255 range
				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(164)
				expect(serialized[2]).to.equal(189)
				expect(serialized[3]).to.equal(71)

				-- Server → Studio (PropertyConverter)
				local deserialized = PropertyConverter.convertPropertyValue("Color", serialized)

				-- Verify deserialized value matches original
				expect(typeof(deserialized)).to.equal("Color3")
				expect(math.floor(deserialized.R * 255)).to.equal(164)
				expect(math.floor(deserialized.G * 255)).to.equal(189)
				expect(math.floor(deserialized.B * 255)).to.equal(71)

				part:Destroy()
			end)

			it("should round-trip different color values", function()
				local part = Instance.new("Part")
				local testColors = {
					Color3.fromRGB(255, 0, 0), -- Red
					Color3.fromRGB(0, 255, 0), -- Green
					Color3.fromRGB(0, 0, 255), -- Blue
					Color3.fromRGB(255, 255, 255), -- White
					Color3.fromRGB(0, 0, 0), -- Black
				}

				for _, originalColor in ipairs(testColors) do
					local serialized = PropertySerializer.serializePropertyValue("Color", part, originalColor)
					local deserialized = PropertyConverter.convertPropertyValue("Color", serialized)

					expect(typeof(deserialized)).to.equal("Color3")
					expect(math.floor(deserialized.R * 255)).to.equal(math.floor(originalColor.R * 255))
					expect(math.floor(deserialized.G * 255)).to.equal(math.floor(originalColor.G * 255))
					expect(math.floor(deserialized.B * 255)).to.equal(math.floor(originalColor.B * 255))
				end

				part:Destroy()
			end)
		end)

		describe("Vector3", function()
			it("should round-trip Vector3 values", function()
				local part = Instance.new("Part")
				local originalSize = Vector3.new(4, 1, 2)

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Size", part, originalSize)

				-- Verify serialized format: [X, Y, Z]
				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(4)
				expect(serialized[2]).to.equal(1)
				expect(serialized[3]).to.equal(2)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("Size", serialized)

				expect(typeof(deserialized)).to.equal("Vector3")
				expect(deserialized.X).to.equal(4)
				expect(deserialized.Y).to.equal(1)
				expect(deserialized.Z).to.equal(2)

				part:Destroy()
			end)

			it("should round-trip various Vector3 values", function()
				local part = Instance.new("Part")
				local testVectors = {
					Vector3.new(0, 0, 0),
					Vector3.new(1, 1, 1),
					Vector3.new(10.5, 20.3, 30.7),
					Vector3.new(-5, -10, -15),
				}

				for _, originalVector in ipairs(testVectors) do
					local serialized = PropertySerializer.serializePropertyValue("Position", part, originalVector)
					local deserialized = PropertyConverter.convertPropertyValue("Position", serialized)

					expect(typeof(deserialized)).to.equal("Vector3")
					expect(deserialized.X).to.equal(originalVector.X)
					expect(deserialized.Y).to.equal(originalVector.Y)
					expect(deserialized.Z).to.equal(originalVector.Z)
				end

				part:Destroy()
			end)
		end)

		describe("CFrame", function()
			it("should round-trip CFrame position values", function()
				local part = Instance.new("Part")
				local originalCFrame = CFrame.new(10, 20, 30)
				part.CFrame = originalCFrame

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("CFrame", part, originalCFrame)

				-- Verify serialized format: {Position: [...], Orientation: [...]}
				expect(type(serialized)).to.equal("table")
				expect(type(serialized.Position)).to.equal("table")
				expect(type(serialized.Orientation)).to.equal("table")
				expect(serialized.Position[1]).to.equal(10)
				expect(serialized.Position[2]).to.equal(20)
				expect(serialized.Position[3]).to.equal(30)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("CFrame", serialized)

				expect(typeof(deserialized)).to.equal("CFrame")
				expect(deserialized.Position.X).to.equal(10)
				expect(deserialized.Position.Y).to.equal(20)
				expect(deserialized.Position.Z).to.equal(30)

				part:Destroy()
			end)
		end)

		describe("UDim2", function()
			it("should round-trip UDim2 values", function()
				local frame = Instance.new("Frame")
				local originalSize = UDim2.new(0.5, 10, 1, 20)
				frame.Size = originalSize

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Size", frame, originalSize)

				-- Verify serialized format: {X: [Scale, Offset], Y: [Scale, Offset]}
				expect(type(serialized)).to.equal("table")
				expect(type(serialized.X)).to.equal("table")
				expect(type(serialized.Y)).to.equal("table")
				expect(serialized.X[1]).to.equal(0.5)
				expect(serialized.X[2]).to.equal(10)
				expect(serialized.Y[1]).to.equal(1)
				expect(serialized.Y[2]).to.equal(20)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("Size", serialized)

				expect(typeof(deserialized)).to.equal("UDim2")
				expect(deserialized.X.Scale).to.equal(0.5)
				expect(deserialized.X.Offset).to.equal(10)
				expect(deserialized.Y.Scale).to.equal(1)
				expect(deserialized.Y.Offset).to.equal(20)

				frame:Destroy()
			end)

			it("should round-trip various UDim2 values", function()
				local frame = Instance.new("Frame")
				local testUDim2s = {
					UDim2.new(0, 0, 0, 0),
					UDim2.new(1, 0, 1, 0),
					UDim2.new(0.5, 100, 0.5, 50),
				}

				for _, originalUDim2 in ipairs(testUDim2s) do
					local serialized = PropertySerializer.serializePropertyValue("Position", frame, originalUDim2)
					local deserialized = PropertyConverter.convertPropertyValue("Position", serialized)

					expect(typeof(deserialized)).to.equal("UDim2")
					expect(deserialized.X.Scale).to.equal(originalUDim2.X.Scale)
					expect(deserialized.X.Offset).to.equal(originalUDim2.X.Offset)
					expect(deserialized.Y.Scale).to.equal(originalUDim2.Y.Scale)
					expect(deserialized.Y.Offset).to.equal(originalUDim2.Y.Offset)
				end

				frame:Destroy()
			end)
		end)

		describe("EnumItem", function()
			it("should serialize EnumItem to string", function()
				local part = Instance.new("Part")
				local originalMaterial = Enum.Material.Plastic
				part.Material = originalMaterial

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Material", part, originalMaterial)

				-- EnumItem serializes to string name
				expect(type(serialized)).to.equal("string")
				expect(serialized).to.equal("Plastic")

				-- Note: PropertyConverter doesn't auto-convert strings back to EnumItems
				-- The actual property assignment in UpdateProcessor handles that

				part:Destroy()
			end)
		end)

		describe("BrickColor", function()
			it("should round-trip BrickColor values", function()
				local part = Instance.new("Part")
				local originalBrickColor = BrickColor.new("Bright red")
				part.BrickColor = originalBrickColor

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("BrickColor", part, originalBrickColor)

				-- Verify serialized format: string name
				expect(type(serialized)).to.equal("string")
				expect(serialized).to.equal("Bright red")

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("BrickColor", serialized)

				expect(typeof(deserialized)).to.equal("BrickColor")
				expect(deserialized.Name).to.equal("Bright red")

				part:Destroy()
			end)

			it("should round-trip various BrickColor values", function()
				local part = Instance.new("Part")
				local testBrickColors = {
					BrickColor.new("Bright red"),
					BrickColor.new("Bright blue"),
					BrickColor.new("Bright yellow"),
					BrickColor.new("Really black"),
				}

				for _, originalBrickColor in ipairs(testBrickColors) do
					local serialized = PropertySerializer.serializePropertyValue("BrickColor", part, originalBrickColor)
					local deserialized = PropertyConverter.convertPropertyValue("BrickColor", serialized)

					expect(typeof(deserialized)).to.equal("BrickColor")
					expect(deserialized.Name).to.equal(originalBrickColor.Name)
				end

				part:Destroy()
			end)
		end)

		describe("NumberRange", function()
			it("should round-trip NumberRange values", function()
				local part = Instance.new("Part")
				local originalRange = NumberRange.new(0, 10)

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Lifetime", part, originalRange)

				-- Verify serialized format: [Min, Max]
				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(0)
				expect(serialized[2]).to.equal(10)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("Lifetime", serialized)

				expect(typeof(deserialized)).to.equal("NumberRange")
				expect(deserialized.Min).to.equal(0)
				expect(deserialized.Max).to.equal(10)

				part:Destroy()
			end)

			it("should round-trip various NumberRange values", function()
				local part = Instance.new("Part")
				local testRanges = {
					NumberRange.new(0, 1),
					NumberRange.new(5, 15),
					NumberRange.new(0.5, 2.5),
				}

				for _, originalRange in ipairs(testRanges) do
					local serialized = PropertySerializer.serializePropertyValue("Speed", part, originalRange)
					local deserialized = PropertyConverter.convertPropertyValue("Speed", serialized)

					expect(typeof(deserialized)).to.equal("NumberRange")
					expect(deserialized.Min).to.equal(originalRange.Min)
					expect(deserialized.Max).to.equal(originalRange.Max)
				end

				part:Destroy()
			end)
		end)

		describe("Vector2", function()
			it("should round-trip Vector2 values", function()
				local part = Instance.new("Part")
				local originalVector = Vector2.new(10, 20)

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("CustomVector", part, originalVector)

				-- Verify serialized format: [X, Y]
				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(10)
				expect(serialized[2]).to.equal(20)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("CustomVector", serialized)

				expect(typeof(deserialized)).to.equal("Vector2")
				expect(deserialized.X).to.equal(10)
				expect(deserialized.Y).to.equal(20)

				part:Destroy()
			end)
		end)

		describe("GUI UDim2 Round-Trip", function()
			it("should round-trip UDim2 Position from Frame", function()
				local frame = Instance.new("Frame")
				local originalPos = UDim2.new(0.5, 10, 0.25, 20)
				frame.Position = originalPos

				-- Studio → Server (PropertySerializer)
				local serialized = PropertySerializer.serializePropertyValue("Position", frame, originalPos)

				-- Verify serialized format: {X: [Scale, Offset], Y: [Scale, Offset]}
				expect(type(serialized)).to.equal("table")
				expect(serialized.X[1]).to.equal(0.5)
				expect(serialized.X[2]).to.equal(10)
				expect(serialized.Y[1]).to.equal(0.25)
				expect(serialized.Y[2]).to.equal(20)

				-- Server → Studio (PropertyConverter)
				local deserialized = PropertyConverter.convertPropertyValue("Position", serialized)

				expect(typeof(deserialized)).to.equal("UDim2")
				expect(deserialized.X.Scale).to.equal(0.5)
				expect(deserialized.X.Offset).to.equal(10)
				expect(deserialized.Y.Scale).to.equal(0.25)
				expect(deserialized.Y.Offset).to.equal(20)

				frame:Destroy()
			end)

			it("should round-trip BackgroundColor3 from Frame", function()
				local frame = Instance.new("Frame")
				local originalColor = Color3.fromRGB(100, 150, 200)
				frame.BackgroundColor3 = originalColor

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("BackgroundColor3", frame, originalColor)

				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(100)
				expect(serialized[2]).to.equal(150)
				expect(serialized[3]).to.equal(200)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("BackgroundColor3", serialized)

				expect(typeof(deserialized)).to.equal("Color3")
				expect(math.floor(deserialized.R * 255)).to.equal(100)
				expect(math.floor(deserialized.G * 255)).to.equal(150)
				expect(math.floor(deserialized.B * 255)).to.equal(200)

				frame:Destroy()
			end)

			it("should round-trip UDim CornerRadius from UICorner", function()
				local corner = Instance.new("UICorner")
				local originalRadius = UDim.new(0, 12)
				corner.CornerRadius = originalRadius

				-- Studio → Server (serializes as [Scale, Offset])
				local serialized = PropertySerializer.serializePropertyValue("CornerRadius", corner, originalRadius)

				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(0)
				expect(serialized[2]).to.equal(12)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("CornerRadius", serialized)
				expect(typeof(deserialized)).to.equal("UDim")
				expect(deserialized.Scale).to.equal(0)
				expect(deserialized.Offset).to.equal(12)

				corner:Destroy()
			end)

			it("should round-trip UDim PaddingTop from UIPadding", function()
				local padding = Instance.new("UIPadding")
				local originalPadding = UDim.new(0, 8)
				padding.PaddingTop = originalPadding

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("PaddingTop", padding, originalPadding)

				expect(type(serialized)).to.equal("table")
				expect(serialized[1]).to.equal(0)
				expect(serialized[2]).to.equal(8)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("PaddingTop", serialized)
				expect(typeof(deserialized)).to.equal("UDim")
				expect(deserialized.Scale).to.equal(0)
				expect(deserialized.Offset).to.equal(8)

				padding:Destroy()
			end)
		end)

		describe("ColorSequence", function()
			it("should round-trip ColorSequence values", function()
				local part = Instance.new("Part")
				local originalSeq = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 0)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
				})

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Color", part, originalSeq)

				-- Verify serialized format: array of {t, c: [R,G,B]} keypoints
				expect(type(serialized)).to.equal("table")
				expect(#serialized).to.equal(3)
				expect(serialized[1].t).to.equal(0)
				expect(serialized[1].c[1]).to.equal(255)
				expect(serialized[1].c[2]).to.equal(0)
				expect(serialized[1].c[3]).to.equal(0)
				expect(serialized[2].t).to.equal(0.5)
				expect(serialized[2].c[1]).to.equal(0)
				expect(serialized[2].c[2]).to.equal(255)
				expect(serialized[3].t).to.equal(1)
				expect(serialized[3].c[3]).to.equal(255)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("Color", serialized)

				expect(typeof(deserialized)).to.equal("ColorSequence")
				local kps = deserialized.Keypoints
				expect(#kps).to.equal(3)
				expect(kps[1].Time).to.equal(0)
				expect(math.floor(kps[1].Value.R * 255)).to.equal(255)
				expect(kps[2].Time).to.equal(0.5)
				expect(math.floor(kps[2].Value.G * 255)).to.equal(255)
				expect(kps[3].Time).to.equal(1)
				expect(math.floor(kps[3].Value.B * 255)).to.equal(255)

				part:Destroy()
			end)
		end)

		describe("NumberSequence", function()
			it("should round-trip NumberSequence values", function()
				local part = Instance.new("Part")
				local originalSeq = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(0.5, 1),
					NumberSequenceKeypoint.new(1, 0.5),
				})

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("Transparency", part, originalSeq)

				-- Verify serialized format: array of {t, v, e} keypoints
				expect(type(serialized)).to.equal("table")
				expect(#serialized).to.equal(3)
				expect(serialized[1].t).to.equal(0)
				expect(serialized[1].v).to.equal(0)
				expect(serialized[2].t).to.equal(0.5)
				expect(serialized[2].v).to.equal(1)
				expect(serialized[3].t).to.equal(1)
				expect(serialized[3].v).to.equal(0.5)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("Transparency", serialized)

				expect(typeof(deserialized)).to.equal("NumberSequence")
				local kps = deserialized.Keypoints
				expect(#kps).to.equal(3)
				expect(kps[1].Time).to.equal(0)
				expect(kps[1].Value).to.equal(0)
				expect(kps[2].Time).to.equal(0.5)
				expect(kps[2].Value).to.equal(1)
				expect(kps[3].Time).to.equal(1)
				expect(kps[3].Value).to.equal(0.5)

				part:Destroy()
			end)
		end)

		describe("Rect", function()
			it("should round-trip Rect values", function()
				local part = Instance.new("Part")
				local originalRect = Rect.new(10, 20, 100, 200)

				-- Studio → Server
				local serialized = PropertySerializer.serializePropertyValue("SliceCenter", part, originalRect)

				-- Verify serialized format: {Min: [X, Y], Max: [X, Y]}
				expect(type(serialized)).to.equal("table")
				expect(serialized.Min[1]).to.equal(10)
				expect(serialized.Min[2]).to.equal(20)
				expect(serialized.Max[1]).to.equal(100)
				expect(serialized.Max[2]).to.equal(200)

				-- Server → Studio
				local deserialized = PropertyConverter.convertPropertyValue("SliceCenter", serialized)

				expect(typeof(deserialized)).to.equal("Rect")
				expect(deserialized.Min.X).to.equal(10)
				expect(deserialized.Min.Y).to.equal(20)
				expect(deserialized.Max.X).to.equal(100)
				expect(deserialized.Max.Y).to.equal(200)

				part:Destroy()
			end)
		end)

		describe("Simple types", function()
			it("should round-trip boolean values", function()
				local part = Instance.new("Part")

				local serializedTrue = PropertySerializer.serializePropertyValue("Anchored", part, true)
				expect(serializedTrue).to.equal(true)
				expect(PropertyConverter.convertPropertyValue("Anchored", serializedTrue)).to.equal(true)

				local serializedFalse = PropertySerializer.serializePropertyValue("CanCollide", part, false)
				expect(serializedFalse).to.equal(false)
				expect(PropertyConverter.convertPropertyValue("CanCollide", serializedFalse)).to.equal(false)

				part:Destroy()
			end)

			it("should round-trip string values", function()
				local part = Instance.new("Part")

				local serialized = PropertySerializer.serializePropertyValue("Name", part, "TestPart")
				expect(serialized).to.equal("TestPart")
				expect(PropertyConverter.convertPropertyValue("Name", serialized)).to.equal("TestPart")

				part:Destroy()
			end)

			it("should round-trip number values", function()
				local part = Instance.new("Part")

				local serialized = PropertySerializer.serializePropertyValue("Transparency", part, 0.5)
				expect(serialized).to.equal(0.5)
				expect(PropertyConverter.convertPropertyValue("Transparency", serialized)).to.equal(0.5)

				part:Destroy()
			end)
		end)
	end)
end
