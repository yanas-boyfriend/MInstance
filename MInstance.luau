--!optimize 2

local NULL = nil
local EMPTY_TABLE = {}

local AssetService = game:GetService("AssetService")
local ReflectionServiceWrapper = require(script.DefaultProperties)
local BufferEncoder = require(script.BufferEncoder)
local OldCompress = require(script.OldCompress)
local NewCompress = require(script.NewCompress)
local Base94 = require(script.Encoders.Base94)
local CreateInstanceMap, ReverseInstanceMap -- these function are declared this way because they will be calling themselves
local InstanceReferenceCache = {}
local CreatableInstancesCache = {}
local PropertiesOfClassCache = {}
local Minstance = {}

local InstanceCreationInternalHooks = {}

-- localize luau api functions for faster access, avoid having to invoke the internal metamethods to fetch a function like "new" from Instance (Instance.new)
local Instance_new = Instance.new
local table_insert = table.insert
local table_create = table.create
local string_format = string.format
local buffer_tostring = buffer.tostring
local buffer_fromstring = buffer.fromstring
local table_clear = table.clear
local debug_info = debug.info
local os_clock = os.clock
local typeof = typeof
local type = type
local ipairs = ipairs

local __index = function(Object, Index)
	return Object[Index]
end

local __newindex = function(Object, Index, New)
	Object[Index] = New
end

-- see if we can fetch the internal metamethods for faster indexing and newindexing (proven to be 15% faster! WOW!)
pcall(function()
	local TemporaryInstance = Instance_new("Part")

	local SuspectedIndex = select(2, xpcall(function()
		return game.___
	end, function()
		return debug_info(2, "f")
	end))

	local SuspectedNewindex = select(2, xpcall(function()
		game.___ = NULL
	end, function()
		return debug_info(2, "f")
	end))

	SuspectedNewindex(TemporaryInstance, "Name", "i love my girlfriend yana")

	if TemporaryInstance.Name == "i love my girlfriend yana" then
		__newindex = SuspectedNewindex
	end

	if SuspectedIndex(TemporaryInstance, "Name") == "i love my girlfriend yana" then
		__index = SuspectedIndex
	end

	TemporaryInstance:Destroy()
end)

if ReflectionServiceWrapper.InitializeApiDump() ~= true then
	return error("Failed to initialize API. Minstance will not work.")
end

local IsClassCreatable = function(ClassName)
	local Cached = CreatableInstancesCache[ClassName]
	
	if Cached then
		return Cached
	end
	
	local Status, TestInstance = pcall(Instance_new, ClassName)

	if not Status or TestInstance == NULL then
		CreatableInstancesCache[ClassName] = false
		
		return false
	else
		pcall(function()
			TestInstance:Destroy()
		end)
		
		CreatableInstancesCache[ClassName] = true

		return true
	end
end

local SafelyIndexInto = function(Object, Index)
	local Status, Value = pcall(function()
		return __index(Object, Index)
	end)

	if Status then
		return Status, Value
	else
		return Status
	end
end

local ThrowToConsole = function(Message, Type)
	if Type == 2 then
		return error(`[Minstance] {Message}`)
		-- elseif Type == 1 then
		-- return warn(`[Minstance] {Message}`)
		-- end
	end

	-- return print(`[Minstance] {Message}`)
	return warn(`[Minstance] {Message}`)
end

local CreateAddressFromDescendantToParent = function(Descendant, Parent)
	local Address = {}
	local CurrentDescendant = Descendant
	
	if Descendant == Parent then
		return {0}
	end
	
	while CurrentDescendant and CurrentDescendant ~= Parent do
		local DescendantParent = __index(CurrentDescendant, "Parent")
		
		if not DescendantParent then
			return {}
		end
		
		local Position = 0
		
		for i, Child in ipairs(DescendantParent:GetChildren()) do
			if Child == CurrentDescendant then
				Position = i
				break
			end
		end

		table_insert(Address, 1, Position)

		CurrentDescendant = DescendantParent
	end

	return Address
end

CreateInstanceMap = function(TargetInstance, IncludeDescendants, PrintProcess, MainInstanceReference, IncludeAttributes, DisallowedProperties)
	local ClassName = __index(TargetInstance, "ClassName")

	local Map = {
		ClassName = ClassName,
		Properties = {}
	}

	if not IsClassCreatable(ClassName) then
		ThrowToConsole(`Skipping Instance "{TargetInstance:GetFullName()}" ({ClassName}) because it is not creatable.`)
		return
	end

	local FreshInstance, PropertiesOfClass
	local PropertiesInMap = Map.Properties
	local FoundValidPropertyOnce = false
	local CachedFreshInstance = InstanceReferenceCache[ClassName]
	local PropertiesCache = PropertiesOfClassCache[ClassName]
	
	if PropertiesCache then
		PropertiesOfClass = PropertiesCache
	else
		PropertiesOfClass = ReflectionServiceWrapper.GetPropertiesOfClass(ClassName)
		PropertiesOfClassCache[ClassName] = PropertiesOfClass
	end
	
	if CachedFreshInstance then
		FreshInstance = CachedFreshInstance
	else
		FreshInstance = Instance_new(ClassName)
		InstanceReferenceCache[ClassName] = FreshInstance
	end

	for _, Property in ipairs(PropertiesOfClass) do
		if DisallowedProperties then
			local List = DisallowedProperties[ClassName]

			if List then
				if List[Property] then
					continue
				end
			end
		end
		
		if not PropertiesInMap[Property] and Property ~= "Parent" then
			local Status, ValueInFreshInstance = SafelyIndexInto(FreshInstance, Property)

			if Status then
				local ValueInOriginalInstance = __index(TargetInstance, Property)

				if ValueInFreshInstance ~= ValueInOriginalInstance then
					if not FoundValidPropertyOnce then
						FoundValidPropertyOnce = true
					end
					
					if typeof(ValueInOriginalInstance) == "Instance" then -- this is rare to occur
						if ValueInOriginalInstance == MainInstanceReference then
							PropertiesInMap[Property] = {["Pointer"] = {0}}
						else
							if ValueInOriginalInstance:IsDescendantOf(MainInstanceReference) then
								local Pointer = CreateAddressFromDescendantToParent(ValueInOriginalInstance, MainInstanceReference)
								
								if #Pointer >= 1 then
									PropertiesInMap[Property] = {["Pointer"] = Pointer}
								end
							else
								ThrowToConsole(`Skipping property "{Property}" of Instance "{TargetInstance:GetFullName()}" ({ClassName}) because the value of the property references an Instance that is not a descendant of the main Instance being serialized.`)
							end
						end
					else
						PropertiesInMap[Property] = ValueInOriginalInstance
					end
				end
			end
		end
	end

	if not FoundValidPropertyOnce then
		Map.Properties = NULL
	end
	
	if IncludeAttributes then
		local Attributes = TargetInstance:GetAttributes()
		
		for _ in pairs(Attributes) do
			Map.Attributes = Attributes
			break
		end
	end

	-- if PrintProcess then
		-- ThrowToConsole(`Mapping Instance "{TargetInstance:GetFullName()}" ({ClassName})...`)
	-- end

	if IncludeDescendants then
		local Children = TargetInstance:GetChildren()
		local ChildrenCount = #Children

		if ChildrenCount > 0 then
			Map.Children = table_create(ChildrenCount)

			for _, Child in ipairs(Children) do
				local NewInstanceMap = CreateInstanceMap(Child, true, PrintProcess, MainInstanceReference, IncludeAttributes, DisallowedProperties)

				if NewInstanceMap then
					table_insert(Map.Children, NewInstanceMap)
				end
			end
		end
	end

	return Map
end

-- support meshparts deserialization
local CreateMeshPart = function(Id, Options)
	local Success, ErrorOrMeshPart = pcall(function()
		return AssetService:CreateMeshPartAsync(Id, Options)
	end)
	
	if Success then
		return ErrorOrMeshPart
	else
		ThrowToConsole(`Failed to create MeshPart with content ID "{tostring(Id)}". Returning default MeshPart. Error: {ErrorOrMeshPart}`)
		return Instance_new("MeshPart")
	end
end

InstanceCreationInternalHooks.MeshPart = function(Properties)
	local Id = Properties.MeshId
	local CollisionFidelity = Properties.CollisionFidelity
	local RenderFidelity = Properties.RenderFidelity
	local FluidFidelity = Properties.FluidFidelity
	local Options = {}
	
	if CollisionFidelity then
		Options["CollisionFidelity"] = CollisionFidelity
	end
	
	if RenderFidelity then
		Options["RenderFidelity"] = RenderFidelity
	end
	
	if FluidFidelity then
		Options["FluidFidelity"] = FluidFidelity
	end
	
	-- this code is chain of if nots is here on purpose
	if not CollisionFidelity and not RenderFidelity and not FluidFidelity then
		Options = nil
	end
	
	return CreateMeshPart(Id, Options), { -- avoid setting these properties for cpu cycles to not go to waste
		MeshId = true,
		CollisionFidelity = true,
		RenderFidelity = true,
		FluidFidelity = true,
		MeshContent = true
	}
end

ReverseInstanceMap = function(Map, ParentOfInstance, DeserializeMeshPartsProperly, MainMapReference, TemporaryCacheTable)
	local ClassName = Map.ClassName
	local Properties = Map.Properties
	local Children = Map.Children
	local Attributes = Map.Attributes
	local CallbackFunction = Map.Callback
	local InternalPropertyHooks = EMPTY_TABLE
	local UseInternalPropertyHooks = false -- CPU CYCLES MUST NOT GO TO WASTE!!
	local CreationHook = InstanceCreationInternalHooks[ClassName]
	local MainInstance
	
	if CreationHook then
		if ClassName == "MeshPart" then
			if DeserializeMeshPartsProperly then
				UseInternalPropertyHooks = true
				MainInstance, InternalPropertyHooks = CreationHook(Properties)
			else
				MainInstance = Instance_new(ClassName)
			end
		else
			MainInstance = CreationHook(Properties)
		end
	else
		MainInstance = Instance_new(ClassName)
	end
	
	local SafelySetProperty = function(Property, Value)
		local Status, Error = pcall(function()
			__newindex(MainInstance, Property, Value)
		end)
		
		if not Status then
			ThrowToConsole(`Unable to set property {Property} to Instance "{tostring(MainInstance)}" ({ClassName}) for reason: "{Error}"`)
		end
	end
	
	TemporaryCacheTable[Map] = MainInstance
	
	if CallbackFunction then
		CallbackFunction(MainInstance)
	end

	if ParentOfInstance then
		__newindex(MainInstance, "Parent", ParentOfInstance)
	end

	if Properties then
		for Property, Value in pairs(Properties) do
			if type(Value) == "table" then
				local Location = Value.Pointer
				
				if type(Location) == "table" then
					if #Location >= 1 then
						local CurrentlyPointingTo = NULL
						
						if #Location == 1 and Location[1] == 0 then
							CurrentlyPointingTo = MainMapReference
						else
							for _, Index in ipairs(Location) do
								if CurrentlyPointingTo then
									local ChildrenList = CurrentlyPointingTo.Children

									if ChildrenList then
										local IsValidMap = ChildrenList[Index]

										if IsValidMap then
											CurrentlyPointingTo = IsValidMap
										else
											ThrowToConsole(`Skipped setting property "{Property}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
											break
										end
									end
								else
									local ChildrenList = MainMapReference.Children

									if ChildrenList then
										local IsValidMap = ChildrenList[Index]

										if IsValidMap then
											CurrentlyPointingTo = IsValidMap
										else
											ThrowToConsole(`Skipped setting property "{Property}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
											break
										end
									end
								end
							end
						end
						
						local CachedInstance = TemporaryCacheTable[CurrentlyPointingTo]
						
						if CachedInstance then
							SafelySetProperty(Property, CachedInstance)
						else
							CurrentlyPointingTo.Callback = function(GotInstance)
								SafelySetProperty(Property, GotInstance)
							end
						end
					else
						ThrowToConsole(`Skipped setting property "{Property}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
					end
				end
			else
				if UseInternalPropertyHooks then -- CPU CYCLES MUST NOT GO TO WASTE!!
					if InternalPropertyHooks[Property] then
						continue
					end
				end
				
				SafelySetProperty(Property, Value)
			end
		end
	end
	
	if Attributes then
		for Name, Value in pairs(Attributes) do
			MainInstance:SetAttribute(Name, Value)
		end
	end
	
	if Children then
		for _, Child in ipairs(Children) do
			ReverseInstanceMap(Child, MainInstance, DeserializeMeshPartsProperly, MainMapReference, TemporaryCacheTable)
		end
	end

	return MainInstance
end

Minstance.SerializeInstance = function(TargetInstance: Instance, SerializationSettings: {
	IncludeDescendants: boolean,
	CompressSerializedData: boolean,
	EncodeInBase94: boolean,
	AnnoyingConsolePrints: boolean,
	UseLegacySlowCompressor: boolean,
	IncludeAttributes: boolean,
	DisallowedProperties: {[string]: {[string]: any} } | nil
	})
	
	local IncludeDescendants, CompressSerializedData, EncodeInBase94, AnnoyingConsolePrints, UseLegacySlowCompressor, IncludeAttributes, DisallowedProperties, StartBenchmarkTime

	local DefaultSerializationSettings = {
		IncludeDescendants = true,
		CompressSerializedData = true,
		EncodeInBase94 = false,
		AnnoyingConsolePrints = false,
		UseLegacySlowCompressor = false,
		IncludeAttributes = true,
		DisallowedProperties = NULL
		-- EXAMPLE:
		-- {
			--	["Part"] = {
			--		["BrickColor"] = true
			--	}
		-- }
	}

	if not SerializationSettings then
		SerializationSettings = DefaultSerializationSettings
	end
	
	for Setting in pairs(DefaultSerializationSettings) do
		if SerializationSettings[Setting] == NULL then
			return ThrowToConsole(`Please provide add all settings to SerializationSettings. Missing "{Setting}".`, 2)
		end
	end
	
	IncludeDescendants = SerializationSettings.IncludeDescendants
	CompressSerializedData = SerializationSettings.CompressSerializedData
	EncodeInBase94 = SerializationSettings.EncodeInBase94
	AnnoyingConsolePrints = SerializationSettings.AnnoyingConsolePrints
	UseLegacySlowCompressor = SerializationSettings.UseLegacySlowCompressor
	IncludeAttributes = SerializationSettings.IncludeAttributes
	DisallowedProperties = SerializationSettings.DisallowedProperties

	if not ReflectionServiceWrapper.IsApiInitialized() then
		return ThrowToConsole(`There was a problem with initalizing the API and Minstance can not serialize an Instance. Please get in contact with @WalletOverflow in Roblox and let them know about this, and please show recent console errors coming from this module.`, 2)
	end

	if typeof(TargetInstance) ~= "Instance" then
		return ThrowToConsole(`Invalid first argument passed into SerializeInstance! Expected: Instance`, 2)
	end

	if not IsClassCreatable(TargetInstance.ClassName) then
		return ThrowToConsole(`Instance "{TargetInstance:GetFullName()}" ({TargetInstance.ClassName}) is not creatable and can not be serialized.`, 2)
	end

	if AnnoyingConsolePrints then
		ThrowToConsole(`You are seeing this because AnnoyingConsolePrints setting was set to true in SerializationSettings.`)
		ThrowToConsole(`Target Instance: "{TargetInstance:GetFullName()}" ({TargetInstance.ClassName}) ({tostring(#TargetInstance:GetDescendants())} descendants)`)
		ThrowToConsole(`Mapping Instance...`)

		StartBenchmarkTime = os_clock()
	end

	local MainMap = CreateInstanceMap(TargetInstance, IncludeDescendants, AnnoyingConsolePrints, TargetInstance, IncludeAttributes, DisallowedProperties)
	
	if AnnoyingConsolePrints then
		if IncludeDescendants then
			ThrowToConsole(string_format(`Finished serializing/mapping "{TargetInstance:GetFullName()}" (and {tostring(#TargetInstance:GetDescendants())} descendants) in %.4fs!`, os_clock() - StartBenchmarkTime))
		else
			ThrowToConsole(string_format(`Finished serializing/mapping "{TargetInstance:GetFullName()}" in %.4fs!`, os_clock() - StartBenchmarkTime))
		end
	end
	
	local BinaryEncoded = BufferEncoder.write(MainMap)

	if not CompressSerializedData then
		if EncodeInBase94 then
			return buffer_tostring(Base94.encode(BinaryEncoded))
		else
			return buffer_tostring(BinaryEncoded)
		end
	else
		if AnnoyingConsolePrints then
			ThrowToConsole(`Attempting to compress serialized data...`)
			StartBenchmarkTime = os_clock()
		end
		
		local BinaryEncodedString = buffer_tostring(BinaryEncoded)

		if UseLegacySlowCompressor then
			if EncodeInBase94 then
				local FinalCompressedData = OldCompress.Compress(BinaryEncodedString)

				if AnnoyingConsolePrints then
					ThrowToConsole(string_format(`Finished compressing & encoding serialized data in %.4fs!`, os_clock() - StartBenchmarkTime))
					ThrowToConsole(`Serialized data character count before compression: {#BinaryEncodedString}`)
					ThrowToConsole(`Serialized data character count after compression: {#FinalCompressedData}`)
				end

				return FinalCompressedData
			else
				local FinalCompressedData = OldCompress.CompressNoEncoding(BinaryEncodedString)

				if AnnoyingConsolePrints then
					ThrowToConsole(string_format(`Finished compressing serialized data in %.4fs!`, os_clock() - StartBenchmarkTime))
					ThrowToConsole(`Serialized data character count before compression: {#BinaryEncodedString}`)
					ThrowToConsole(`Serialized data character count after compression: {#FinalCompressedData}`)
				end

				return FinalCompressedData
			end
		else
			local Success, Compressed = pcall(function()
				return NewCompress.Compress(BinaryEncodedString)
			end)
			
			if not Success then
				if Compressed:match("String passed is too short to compress.") then -- TODO: implemetn proper fix and not this bandaid solution just beacause i have to sleep soon
					-- TODO: implemetn proper fix and not this bandaid solution just beacause i have to sleep soon
					MainMap[string.rep("a", 20)] = true
					BinaryEncoded = BufferEncoder.write(MainMap)
					BinaryEncodedString = buffer_tostring(BinaryEncoded)
					Compressed = NewCompress.Compress(BinaryEncodedString)
				else
					return error(Compressed)
				end
			end
			
			if EncodeInBase94 then
				local Base94Encoded = buffer_tostring(Base94.encode(buffer_fromstring(Compressed)))
				
				if AnnoyingConsolePrints then
					ThrowToConsole(string_format(`Finished compressing & encoding serialized data in %.4fs!`, os_clock() - StartBenchmarkTime))
					ThrowToConsole(`Serialized data character count before compression: {#BinaryEncodedString}`)
					ThrowToConsole(`Serialized data character count after compression: {#Base94Encoded}`)
				end
				
				return Base94Encoded
			else
				if AnnoyingConsolePrints then
					ThrowToConsole(string_format(`Finished compressing serialized data in %.4fs!`, os_clock() - StartBenchmarkTime))
					ThrowToConsole(`Serialized data character count before compression: {#BinaryEncodedString}`)
					ThrowToConsole(`Serialized data character count after compression: {#Compressed}`)
				end
				
				return Compressed
			end
		end
	end
end

Minstance.DeserializeInstance = function(SerializedData: string, DeserializationSettings: {
	IsDataCompressed: boolean,
	IsBase94Encoded: boolean,
	AnnoyingConsolePrints: boolean,
	IsCompressedWithLegacyCompressor: boolean,
	ProperlyDeserializeMeshParts: boolean,
	ParentInstanceWhileDeserializing: Instance?
	})
	
	local IsDataCompressed, IsBase94Encoded, AnnoyingConsolePrints, IsCompressedWithLegacyCompressor, ProperlyDeserializeMeshParts, ParentInstanceWhileDeserializing, StartBenchmarkTime, MainMap
	
	local DefaultDeserializationSettings = {
		IsDataCompressed = true,
		IsBase94Encoded = false,
		AnnoyingConsolePrints = false,
		IsCompressedWithLegacyCompressor = false,
		ProperlyDeserializeMeshParts = false, -- load mesh parts, if off then put mesh put but not load content
		ParentInstanceWhileDeserializing = NULL
	}
	
	if not DeserializationSettings then
		DeserializationSettings = DefaultDeserializationSettings
	end
	
	for Setting in pairs(DefaultDeserializationSettings) do
		if DeserializationSettings[Setting] == NULL then
			return ThrowToConsole(`Please provide add all settings to SerializationSettings. Missing "{Setting}".`, 2)
		end
	end

	IsDataCompressed = DeserializationSettings.IsDataCompressed
	IsBase94Encoded = DeserializationSettings.IsBase94Encoded
	AnnoyingConsolePrints = DeserializationSettings.AnnoyingConsolePrints
	IsCompressedWithLegacyCompressor = DeserializationSettings.IsCompressedWithLegacyCompressor
	ProperlyDeserializeMeshParts = DeserializationSettings.ProperlyDeserializeMeshParts
	ParentInstanceWhileDeserializing = DeserializationSettings.ParentInstanceWhileDeserializing

	if not ReflectionServiceWrapper.IsApiInitialized() then
		return ThrowToConsole(`There was a problem with initalizing the API and Minstance can not deserialize an Instance. Please get in contact with @WalletOverflow in Roblox and let them know about this, and please show recent console errors coming from this module.`, 2)
	end

	if typeof(SerializedData) ~= "string" then
		return ThrowToConsole(`Invalid first argument passed into DeserializeInstance! Expected: string`, 2)
	end

	if AnnoyingConsolePrints then
		ThrowToConsole(`You are seeing this because AnnoyingConsolePrints setting was set to true in SerializationSettings.`)
		ThrowToConsole(`Processing serialized data...`)

		StartBenchmarkTime = os_clock()
	end

	if IsDataCompressed then
		if IsCompressedWithLegacyCompressor then
			if IsBase94Encoded then
				local BinaryFormat = OldCompress.Decompress(SerializedData)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat))
			else
				local BinaryFormat = OldCompress.DecompressNoEncoding(SerializedData)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat))
			end
		else
			if IsBase94Encoded then
				local Base94Decoded = buffer_tostring(Base94.decode(buffer_fromstring(SerializedData)))
				local BinaryFormat = NewCompress.Decompress(Base94Decoded)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat))
			else
				local BinaryFormat = NewCompress.Decompress(SerializedData)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat))
			end
		end
	else
		if IsBase94Encoded then
			local BinaryBuffer = Base94.decode(buffer_fromstring(SerializedData))

			MainMap = BufferEncoder.read(BinaryBuffer)
		else
			MainMap = BufferEncoder.read(buffer_fromstring(SerializedData))
		end
	end

	if AnnoyingConsolePrints then
		ThrowToConsole(string_format(`Finished processing serialized data in %.4fs!`, os_clock() - StartBenchmarkTime))
		ThrowToConsole(`Attempting to demap/deserialize serialized data into Instance...`)

		StartBenchmarkTime = os_clock()
	end
	
	local MapReversalCache = {}
	local MainInstance = ReverseInstanceMap(MainMap, ParentInstanceWhileDeserializing, ProperlyDeserializeMeshParts, MainMap, MapReversalCache)
	
	table_clear(MapReversalCache)

	if AnnoyingConsolePrints then
		ThrowToConsole(string_format(`Finished demapping/deserializing serialized data into an Instance in %.4fs!`, os_clock() - StartBenchmarkTime))
	end

	return MainInstance
end

-- Minstance.CreateInstanceMap = CreateInstanceMap
-- Minstance.ReverseInstanceMap = ReverseInstanceMap

return Minstance
