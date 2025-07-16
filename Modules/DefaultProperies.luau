-- TODO: replace with ReflectionService when available

local HttpService = game:GetService("HttpService")
local RawApiDump = script:FindFirstChildWhichIsA("Configuration")
local IsApiInitialized = false
local Classes = {}
local DefaultProperties = {}

DefaultProperties.InitializeApiDump = function()
	local Dump = RawApiDump:GetAttribute("Dump")
	local Decoded = HttpService:JSONDecode(Dump)
	local DecodedClasses = Decoded.Classes
	
	for Position, Class in pairs(DecodedClasses) do
		local Tags = Class.Tags
		local Members = Class.Members
		local ClassName = Class.Name
		
		-- filter out services
		if Tags then
			for _, Tag in pairs(Tags) do
				if Tag == "Service" then
					DecodedClasses[Position] = nil
					continue
				end
			end
		end
		
		-- filter out properties locked behind capabilities, filter out members that are not properties, filter out hidden properties, etc
		if Members then
			for MemberPosition, Property in pairs(Members) do
				local Type = Property.MemberType
				local Tags = Property.Tags
				local Name = Property.Name
				local NameFirstLetter = Name:sub(1, 1)
				local Security = Property.Security
				local SecurityType = type(Security)
				
				if Type ~= "Property" then
					Members[MemberPosition] = nil
					continue
				end
				
				if Tags then
					for _, Tag in pairs(Tags) do
						if Tag == "NotScriptable" or Tag == "ReadOnly" then
							Members[MemberPosition] = nil
							continue
						end
					end
				end
				
				-- filter out legacy property references
				if NameFirstLetter == NameFirstLetter:lower() then
					Members[MemberPosition] = nil
					continue
				end
				
				if SecurityType == "string" then
					if Security ~= "None" then
						Members[MemberPosition] = nil
						continue
					end
				elseif SecurityType == "table" then
					if Security.Read ~= "None" then -- we will include properties that can be read but not written
						Members[MemberPosition] = nil
						continue
					end
				end
			end
		end
	end
	
	for _, Class in pairs(DecodedClasses) do
		local Superclass = Class.Superclass
		local Members = Class.Members
		local ClassName = Class.Name
		
		Classes[ClassName] = {
			Superclass = Superclass,
			Members = Members
		}
	end
	
	IsApiInitialized = true
	
	return true
end

DefaultProperties.IsApiInitialized = function()
	return IsApiInitialized
end

DefaultProperties.GetPropertiesOfClass = function(ClassName)
	local Properties = {}
	local IterateThroughProperties
	
	IterateThroughProperties = function(ClassName)
		local ClassInfo = Classes[ClassName]
		
		if ClassInfo then
			local Members = ClassInfo.Members
			local Superclass = ClassInfo.Superclass

			for Position, Property in pairs(Members) do
				local Name = Property.Name
				
				if not table.find(Properties, Name) then -- todo: dont use table.find and table.insert
					table.insert(Properties, Name)
				end
			end
			
			if Superclass then
				IterateThroughProperties(Superclass)
			end
		end
	end
	
	IterateThroughProperties(ClassName)
	
	return Properties
end

DefaultProperties.GetClasses = function()
	return Classes
end

return DefaultProperties
