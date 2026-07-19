
-- Unit tests for PropertyConverter module

return function()
	local PropertyConverter = require(script.Parent.PropertyConverter)

	describe("PropertyConverter.convertPropertyValue", function()
		describe("Simple types", function()
			it("should return boolean values as-is", function()
				expect(PropertyConverter.convertPropertyValue("Anchored", true)).to.equal(true)
				expect(PropertyConverter.convertPropertyValue("CanCollide", false)).to.equal(false)
			end)

			it("should return string values as-is", function()
				expect(PropertyConverter.convertPropertyValue("Name", "TestPart")).to.equal("TestPart")
			end)

			it("should return number values as-is", function()
				expect(PropertyConverter.convertPropertyValue("Reflectance", 0.5)).to.equal(0.5)
				expect(PropertyConverter.convertPropertyValue("Transparency", 0.3)).to.equal(0.3)
			end)

			it("should return nil as nil", function()
				expect(PropertyConverter.convertPropertyValue("SomeProperty", nil)).to.equal(nil)
			end)
		end)

		describe("Color3 properties", function()
			it("should convert RGB color arrays (values > 1) to Color3.fromRGB", function()
				local result = PropertyConverter.convertPropertyValue("Color", { 255, 128, 64 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Color3")
				-- Use approximate comparison for color values (Roblox normalizes 0-255 to 0-1)
				local expected = Color3.fromRGB(255, 128, 64)
				expect(result.R).to.be.near(expected.R, 0.001)
				expect(result.G).to.be.near(expected.G, 0.001)
				expect(result.B).to.be.near(expected.B, 0.001)
			end)

			it("should convert normalized color arrays (values <= 1) to Color3.new", function()
				local result = PropertyConverter.convertPropertyValue("Color", { 1, 0.5, 0.25 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Color3")
				expect(result.R).to.be.near(1, 0.001)
				expect(result.G).to.be.near(0.5, 0.001)
				expect(result.B).to.be.near(0.25, 0.001)
			end)
		end)

		describe("ColorSequence properties", function()
			it("should convert array of RGB arrays to ColorSequence", function()
				local result = PropertyConverter.convertPropertyValue("Color", {
					{ 255, 0, 0 }, -- Red
					{ 255, 255, 0 }, -- Yellow
					{ 0, 0, 255 }, -- Blue
				})
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("ColorSequence")

				-- Verify keypoints
				local keypoints = result.Keypoints
				expect(#keypoints).to.equal(3)

				-- First keypoint (time=0, red)
				expect(keypoints[1].Time).to.be.near(0, 0.001)
				local expectedRed = Color3.fromRGB(255, 0, 0)
				expect(keypoints[1].Value.R).to.be.near(expectedRed.R, 0.001)
				expect(keypoints[1].Value.G).to.be.near(expectedRed.G, 0.001)
				expect(keypoints[1].Value.B).to.be.near(expectedRed.B, 0.001)

				-- Middle keypoint (time=0.5, yellow)
				expect(keypoints[2].Time).to.be.near(0.5, 0.001)

				-- Last keypoint (time=1, blue)
				expect(keypoints[3].Time).to.be.near(1, 0.001)
				local expectedBlue = Color3.fromRGB(0, 0, 255)
				expect(keypoints[3].Value.R).to.be.near(expectedBlue.R, 0.001)
				expect(keypoints[3].Value.G).to.be.near(expectedBlue.G, 0.001)
				expect(keypoints[3].Value.B).to.be.near(expectedBlue.B, 0.001)
			end)

			it("should handle ColorSequence with 2 colors", function()
				local result = PropertyConverter.convertPropertyValue("Color", {
					{ 255, 255, 255 }, -- White
					{ 0, 0, 0 }, -- Black
				})
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("ColorSequence")

				local keypoints = result.Keypoints
				expect(#keypoints).to.equal(2)
				expect(keypoints[1].Time).to.be.near(0, 0.001)
				expect(keypoints[2].Time).to.be.near(1, 0.001)
			end)
		end)

		describe("Vector3 properties", function()
			it("should convert 3-element arrays to Vector3", function()
				local result = PropertyConverter.convertPropertyValue("Size", { 8, 1, 8 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Vector3")
				expect(result.X).to.equal(8)
				expect(result.Y).to.equal(1)
				expect(result.Z).to.equal(8)
			end)

			it("should handle Position as Vector3", function()
				local result = PropertyConverter.convertPropertyValue("Position", { 10, 5, -3 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Vector3")
				expect(result.X).to.equal(10)
				expect(result.Y).to.equal(5)
				expect(result.Z).to.equal(-3)
			end)
		end)

		describe("Vector2 properties", function()
			it("should convert 2-element arrays to Vector2 for SpreadAngle", function()
				local result = PropertyConverter.convertPropertyValue("SpreadAngle", { 180, 180 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Vector2")
				expect(result.X).to.equal(180)
				expect(result.Y).to.equal(180)
			end)

			it("should convert 2-element arrays to Vector2 for unknown properties", function()
				local result = PropertyConverter.convertPropertyValue("UnknownProp", { 10, 20 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("Vector2")
				expect(result.X).to.equal(10)
				expect(result.Y).to.equal(20)
			end)
		end)

		describe("NumberSequence properties", function()
			it("should convert Transparency to NumberSequence", function()
				local result = PropertyConverter.convertPropertyValue("Transparency", { 0, 1 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberSequence")

				local keypoints = result.Keypoints
				expect(#keypoints).to.equal(2)
				expect(keypoints[1].Value).to.equal(0)
				expect(keypoints[2].Value).to.equal(1)
			end)

			it("should convert Size to NumberSequence", function()
				local result = PropertyConverter.convertPropertyValue("Size", { 0.5, 0.5 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberSequence")

				local keypoints = result.Keypoints
				expect(#keypoints).to.equal(2)
				expect(keypoints[1].Value).to.equal(0.5)
				expect(keypoints[2].Value).to.equal(0.5)
			end)
		end)

		describe("NumberRange properties", function()
			it("should convert Lifetime to NumberRange", function()
				local result = PropertyConverter.convertPropertyValue("Lifetime", { 1, 2 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberRange")
				expect(result.Min).to.equal(1)
				expect(result.Max).to.equal(2)
			end)

			it("should convert Speed to NumberRange", function()
				local result = PropertyConverter.convertPropertyValue("Speed", { 10, 20 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberRange")
				expect(result.Min).to.equal(10)
				expect(result.Max).to.equal(20)
			end)

			it("should convert Rotation to NumberRange", function()
				local result = PropertyConverter.convertPropertyValue("Rotation", { 0, 360 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberRange")
				expect(result.Min).to.equal(0)
				expect(result.Max).to.equal(360)
			end)

			it("should convert RotSpeed to NumberRange", function()
				local result = PropertyConverter.convertPropertyValue("RotSpeed", { 5, 15 })
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("NumberRange")
				expect(result.Min).to.equal(5)
				expect(result.Max).to.equal(15)
			end)
		end)

		describe("CFrame properties", function()
			it("should convert simple CFrame with Position field", function()
				local result = PropertyConverter.convertPropertyValue("CFrame", {
					Position = { 10, 5, -3 },
				})
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("CFrame")
				expect(result.Position.X).to.equal(10)
				expect(result.Position.Y).to.equal(5)
				expect(result.Position.Z).to.equal(-3)
			end)

			it("should convert full CFrame with position and orientation", function()
				local result = PropertyConverter.convertPropertyValue("CFrame", {
					Position = { 0, 5, 0 }, -- PascalCase (Roblox API standard)
					Orientation = { -- PascalCase (Roblox API standard)
						{ 1, 0, 0 },
						{ 0, 1, 0 },
						{ 0, 0, 1 },
					},
				})
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("CFrame")
				expect(result.Position.X).to.equal(0)
				expect(result.Position.Y).to.equal(5)
				expect(result.Position.Z).to.equal(0)
			end)
		end)

		describe("BrickColor properties", function()
			it("should convert BrickColor string to BrickColor", function()
				local result = PropertyConverter.convertPropertyValue("BrickColor", "Bright red")
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("BrickColor")
				expect(result.Name).to.equal("Bright red")
			end)

			it("should handle invalid BrickColor gracefully", function()
				local result = PropertyConverter.convertPropertyValue("BrickColor", "InvalidColorName")
				-- Roblox BrickColor.new() doesn't fail on invalid names - it returns a default BrickColor
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("BrickColor")
			end)
		end)

		describe("Enum properties", function()
			it("should convert enum string with dot notation", function()
				local result = PropertyConverter.convertPropertyValue("Material", "Material.Plastic")
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("EnumItem")
				expect(result).to.equal(Enum.Material.Plastic)
			end)

			it("should convert Shape enum", function()
				local result = PropertyConverter.convertPropertyValue("Shape", "PartType.Ball")
				expect(result).to.be.ok()
				expect(typeof(result)).to.equal("EnumItem")
				expect(result).to.equal(Enum.PartType.Ball)
			end)
		end)

		describe("ParticleEmitter properties (integration)", function()
			it("should correctly convert all ParticleEmitter property types", function()
				-- Color: ColorSequence
				local color = PropertyConverter.convertPropertyValue("Color", {
					{ 255, 0, 0 },
					{ 255, 255, 0 },
					{ 0, 0, 255 },
				})
				expect(typeof(color)).to.equal("ColorSequence")

				-- Transparency: NumberSequence
				local transparency = PropertyConverter.convertPropertyValue("Transparency", { 0, 1 })
				expect(typeof(transparency)).to.equal("NumberSequence")

				-- Size: NumberSequence
				local size = PropertyConverter.convertPropertyValue("Size", { 0.5, 0.5 })
				expect(typeof(size)).to.equal("NumberSequence")

				-- Lifetime: NumberRange
				local lifetime = PropertyConverter.convertPropertyValue("Lifetime", { 1, 2 })
				expect(typeof(lifetime)).to.equal("NumberRange")

				-- Speed: NumberRange
				local speed = PropertyConverter.convertPropertyValue("Speed", { 10, 20 })
				expect(typeof(speed)).to.equal("NumberRange")

				-- SpreadAngle: Vector2
				local spreadAngle = PropertyConverter.convertPropertyValue("SpreadAngle", { 180, 180 })
				expect(typeof(spreadAngle)).to.equal("Vector2")

				-- Acceleration: Vector3
				local acceleration = PropertyConverter.convertPropertyValue("Acceleration", { 0, -10, 0 })
				expect(typeof(acceleration)).to.equal("Vector3")

				-- Enabled: boolean
				local enabled = PropertyConverter.convertPropertyValue("Enabled", false)
				expect(enabled).to.equal(false)

				-- Rate: number
				local rate = PropertyConverter.convertPropertyValue("Rate", 100)
				expect(rate).to.equal(100)
			end)
		end)

		describe("Edge cases", function()
			it("should handle empty arrays", function()
				local result = PropertyConverter.convertPropertyValue("EmptyArray", {})
				-- Should return the array as-is
				expect(result).to.be.a("table")
				expect(#result).to.equal(0)
			end)

			it("should handle arrays with 1 element", function()
				local result = PropertyConverter.convertPropertyValue("SingleElement", { 42 })
				-- Should return the array as-is
				expect(result).to.be.a("table")
				expect(#result).to.equal(1)
				expect(result[1]).to.equal(42)
			end)

			it("should handle arrays with 4+ elements", function()
				local result = PropertyConverter.convertPropertyValue("LongArray", { 1, 2, 3, 4, 5 })
				-- Should return the array as-is
				expect(result).to.be.a("table")
				expect(#result).to.equal(5)
			end)

			it("should handle nested objects for unknown properties", function()
				local result = PropertyConverter.convertPropertyValue("CustomData", {
					foo = "bar",
					nested = { a = 1, b = 2 },
				})
				-- Should return the table as-is
				expect(result).to.be.a("table")
				expect(result.foo).to.equal("bar")
			end)
		end)

		describe("reflection-based dispatch", function()
			-- =====================================================================
			-- Regression: 2026-05-15 investigation
			-- (studio-ambient-color3-vector3) — Color3 properties whose name doesn't
			-- contain "Color" were routed to Vector3 and rejected by Studio.
			-- Lighting is a singleton service; we save/restore its properties so the
			-- test environment is unchanged after the suite runs.
			-- =====================================================================
			describe("Lighting Color3 properties (2026-05-15 regression)", function()
				it("dispatches Lighting.Ambient as Color3 via reflection", function()
					local lighting = game:GetService("Lighting")
					local saved = lighting.Ambient
					local result = PropertyConverter.convertPropertyValue("Ambient", { 255, 200, 150 }, lighting)
					expect(typeof(result)).to.equal("Color3")
					local ok, err = pcall(function()
						lighting.Ambient = result
					end)
					lighting.Ambient = saved
					if not ok then
						-- Surface the actual Studio error so the test output mirrors
						-- the production symptom from fly-logs.txt:263.
						error("Ambient assignment failed: " .. tostring(err))
					end
					expect(ok).to.equal(true)
				end)

				it("dispatches Lighting.OutdoorAmbient as Color3 via reflection", function()
					local lighting = game:GetService("Lighting")
					local saved = lighting.OutdoorAmbient
					local result = PropertyConverter.convertPropertyValue("OutdoorAmbient", { 150, 120, 100 }, lighting)
					expect(typeof(result)).to.equal("Color3")
					local ok, err = pcall(function()
						lighting.OutdoorAmbient = result
					end)
					lighting.OutdoorAmbient = saved
					if not ok then
						error("OutdoorAmbient assignment failed: " .. tostring(err))
					end
					expect(ok).to.equal(true)
				end)

				it("preserves BasePart.Color dispatch (name-match baseline)", function()
					local part = Instance.new("Part")
					local result = PropertyConverter.convertPropertyValue("Color", { 255, 200, 120 }, part)
					expect(typeof(result)).to.equal("Color3")
					local ok = pcall(function()
						part.Color = result
					end)
					expect(ok).to.equal(true)
					part:Destroy()
				end)
			end)

			-- =====================================================================
			-- Regression: 2026-04-23 investigation
			-- (updateinstance-complex-value-coercion) — name-based heuristics
			-- mis-routed values across NumberRange / ColorSequence / NumberSequence /
			-- BrickColor in evals 1014 and 1017.
			-- =====================================================================
			describe("complex datatypes (2026-04-23 regression)", function()
				it("dispatches ParticleEmitter.Color as ColorSequence (not Color3)", function()
					-- Eval 1017 run 2: agent passed `Color: [100, 100, 100]` to a
					-- ParticleEmitter. The name-based path returns Color3; the
					-- property is ColorSequence, so assignment fails. Reflection
					-- should pick ColorSequence based on the actual property type.
					local emitter = Instance.new("ParticleEmitter")
					local result = PropertyConverter.convertPropertyValue("Color", { 100, 100, 100 }, emitter)
					expect(typeof(result)).to.equal("ColorSequence")
					local ok = pcall(function()
						emitter.Color = result
					end)
					expect(ok).to.equal(true)
					emitter:Destroy()
				end)

				it("dispatches ParticleEmitter.Lifetime as NumberRange", function()
					local emitter = Instance.new("ParticleEmitter")
					local result = PropertyConverter.convertPropertyValue("Lifetime", { 2, 5 }, emitter)
					expect(typeof(result)).to.equal("NumberRange")
					local ok = pcall(function()
						emitter.Lifetime = result
					end)
					expect(ok).to.equal(true)
					emitter:Destroy()
				end)

				it("dispatches ParticleEmitter.Size as NumberSequence (baseline — name-match)", function()
					-- Already works today via name-based dispatch (Size + len==2 →
					-- NumberSequence). Included as a regression baseline: the
					-- reflection path must agree with name-based here so adding
					-- the instance arg doesn't change observed behavior on the
					-- working cases.
					local emitter = Instance.new("ParticleEmitter")
					local result = PropertyConverter.convertPropertyValue("Size", { 5, 10 }, emitter)
					expect(typeof(result)).to.equal("NumberSequence")
					local ok = pcall(function()
						emitter.Size = result
					end)
					expect(ok).to.equal(true)
					emitter:Destroy()
				end)

				it("dispatches Motor6D.C0 as CFrame (nested-object reflection)", function()
					-- Today's CFrame branch only fires for `propertyName == "CFrame"`
					-- (PropertyConverter.luau:298). Motor6D.C0 / C1 are CFrame too
					-- but their names don't match, so `{Position:[…], Orientation:[…]}`
					-- is returned as-is and assignment fails with
					-- `CFrame expected, got table`. Reflection should detect the
					-- target type and run the nested-object → CFrame conversion.
					local motor = Instance.new("Motor6D")
					local result = PropertyConverter.convertPropertyValue("C0", {
						Position = { 0, 5, 0 },
						Orientation = { 0, 90, 0 },
					}, motor)
					expect(typeof(result)).to.equal("CFrame")
					local ok = pcall(function()
						motor.C0 = result
					end)
					expect(ok).to.equal(true)
					motor:Destroy()
				end)

				it("dispatches SpawnLocation.TeamColor as BrickColor from string", function()
					-- Eval 1014: agent passed `TeamColor: "Bright red"` and got
					-- `BrickColor expected, got string`. Today's string-side
					-- BrickColor branch only fires when the property name contains
					-- "BrickColor" (PropertyConverter.luau:23), so "TeamColor"
					-- misses it. Reflection should construct a BrickColor from
					-- the string name regardless of property name.
					-- NOTE: this case exercises the reflection probe on a *string*
					-- value, not a table — verifies the probe isn't gated on
					-- `valueType == "table"`.
					local spawn = Instance.new("SpawnLocation")
					local result = PropertyConverter.convertPropertyValue("TeamColor", "Bright red", spawn)
					expect(typeof(result)).to.equal("BrickColor")
					local ok = pcall(function()
						spawn.TeamColor = result
					end)
					expect(ok).to.equal(true)
					spawn:Destroy()
				end)
			end)

			-- =====================================================================
			-- Probe-failure fallback
			-- =====================================================================
			describe("fallback to name-based dispatch", function()
				it("falls through when property doesn't exist on instance", function()
					local part = Instance.new("Part")
					local result = PropertyConverter.convertPropertyValue("NonexistentProp", { 1, 2, 3 }, part)
					-- Same as today's 2-arg fallback (3-element array → Vector3).
					expect(typeof(result)).to.equal("Vector3")
					part:Destroy()
				end)

				it("falls through when instance is nil (2-arg compatibility)", function()
					-- All existing 2-arg tests rely on this; this one pins the
					-- contract.
					local result = PropertyConverter.convertPropertyValue("Color", { 255, 200, 150 })
					expect(typeof(result)).to.equal("Color3")
				end)
			end)
		end)
	end)
end
