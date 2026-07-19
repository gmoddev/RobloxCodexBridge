local function getClassName(instance: Instance): string
	-- Return the appropriate source property name based on instance class
	if instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
		return "Source"
	elseif instance:IsA("StringValue") then
		return "Value"
	else
		-- Default fallback
		return "Source"
	end
end

return getClassName
