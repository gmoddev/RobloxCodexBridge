
-- Unit tests for PropertySerializer

return function()
	local PropertySerializer = require(script.Parent.PropertySerializer)

	describe("serializePropertyValue", function()
		describe("value serialization", function()
			it("should handle value serialization", function()
				local testBuffer = "test123"
				local part = Instance.new("Part")

				local result = PropertySerializer.serializePropertyValue("TestBuffer", part, testBuffer)

				expect(result).to.be.a("string")
				expect(result).to.equal("test123")

				part:Destroy()
			end)

			it("should clean buffers from nested tables in Vector3", function()
				local part = Instance.new("Part")
				part.Size = Vector3.new(4, 1, 2)

				local result = PropertySerializer.serializePropertyValue("Size", part, part.Size)

				expect(result).to.be.a("table")
				expect(result[1]).to.equal(4)
				expect(result[2]).to.equal(1)
				expect(result[3]).to.equal(2)
				-- Ensure no buffers remain
				expect(typeof(result[1])).to.equal("number")

				part:Destroy()
			end)

			it("should clean buffers from nested tables in CFrame", function()
				local part = Instance.new("Part")
				part.CFrame = CFrame.new(10, 20, 30)

				local result = PropertySerializer.serializePropertyValue("CFrame", part, part.CFrame)

				expect(result).to.be.a("table")
				expect(result.Position).to.be.a("table")
				expect(result.Position[1]).to.equal(10)
				expect(result.Position[2]).to.equal(20)
				expect(result.Position[3]).to.equal(30)
				-- Ensure no buffers remain
				expect(typeof(result.Position[1])).to.equal("number")

				part:Destroy()
			end)

			it("should handle simple types without buffers", function()
				local part = Instance.new("Part")

				local boolResult = PropertySerializer.serializePropertyValue("Anchored", part, true)
				expect(boolResult).to.equal(true)

				local stringResult = PropertySerializer.serializePropertyValue("Name", part, "TestPart")
				expect(stringResult).to.equal("TestPart")

				local numberResult = PropertySerializer.serializePropertyValue("Transparency", part, 0.5)
				expect(numberResult).to.equal(0.5)

				part:Destroy()
			end)
		end)
	end)
end
