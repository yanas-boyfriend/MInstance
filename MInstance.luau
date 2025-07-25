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
local PropertyCompressionCount = 0 -- resets every mapping session, make sure to reset inside serializeinstance after use
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
	local Status, Value = pcall(__index, Object, Index)

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

CreateInstanceMap = function(TargetInstance, IncludeDescendants, PrintProcess, MainInstanceReference, IncludeAttributes, DisallowedProperties, PropertyCompression)
	local ClassName = __index(TargetInstance, "ClassName")

	local Map = {
		C = ClassName, -- the key of this dict was previously ClassName, shortened for compression
		P = {} -- the key of this dict was previously Properties, shortened for compression
	}
	
	if not PropertyCompression then
		Map.PC = {} -- the key of this dict was previously PropertyCompression, shortened for compression
		PropertyCompression = Map.PC
	end

	if not IsClassCreatable(ClassName) then
		ThrowToConsole(`Skipping Instance "{TargetInstance:GetFullName()}" ({ClassName}) because it is not creatable.`)
		return
	end

	local FreshInstance, PropertiesOfClass
	local PropertiesInMap = Map.P
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
					
					-- i just realized i can compress my serialized data further by generating a list of properties used in all of the instances and having that list in the main instance map like {Name = 1, BrickColor = 2, ...} and then the properties table of child instances would be {[1] = "name", [2] = enum.some.value}
					local ShortenedProperty = PropertyCompression[Property]
					
					if not ShortenedProperty then
						PropertyCompressionCount = PropertyCompressionCount + 1
						
						PropertyCompression[Property] = PropertyCompressionCount
						ShortenedProperty = PropertyCompressionCount
					end
					
					if typeof(ValueInOriginalInstance) == "Instance" then -- this is rare to occur
						if ValueInOriginalInstance == MainInstanceReference then
							PropertiesInMap[ShortenedProperty] = {["Pointer"] = {0}}
						else
							if ValueInOriginalInstance:IsDescendantOf(MainInstanceReference) then
								local Pointer = CreateAddressFromDescendantToParent(ValueInOriginalInstance, MainInstanceReference)
								
								if #Pointer >= 1 then
									PropertiesInMap[ShortenedProperty] = {["Pointer"] = Pointer}
								end
							else
								ThrowToConsole(`Skipping property "{Property}" of Instance "{TargetInstance:GetFullName()}" ({ClassName}) because the value of the property references an Instance that is not a descendant of the main Instance being serialized.`)
							end
						end
					else
						PropertiesInMap[ShortenedProperty] = ValueInOriginalInstance
					end
				end
			end
		end
	end

	if not FoundValidPropertyOnce then
		Map.P = NULL -- the key of this dict was previously Properties, shortened for compression
	end
	
	if IncludeAttributes then
		local Attributes = TargetInstance:GetAttributes()
		
		for _ in pairs(Attributes) do
			Map.A = Attributes -- the key of this dict was previously Attributes, shortened for compression
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
			Map.K = table_create(ChildrenCount) -- the key of this dict was previously Children, shortened for compression, now set to K as in Kids
			local MicroOptimizationReference = Map.K

			for _, Child in ipairs(Children) do
				local NewInstanceMap = CreateInstanceMap(Child, true, PrintProcess, MainInstanceReference, IncludeAttributes, DisallowedProperties, PropertyCompression)

				if NewInstanceMap then
					table_insert(MicroOptimizationReference, NewInstanceMap)
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

InstanceCreationInternalHooks.MeshPart = function(Properties, InvertedPropertyCompression)
	local Id
	local Options = {}
	local HandledProperties = {}
	
	-- WASTE OF CPU CYCLES I KNOW.. TODO: FIX
	for PropertyId, Value in pairs(Properties) do
		local PropertyName = InvertedPropertyCompression[PropertyId]

		if PropertyName == "MeshContent" then
			if not Id then
				Id = Value
			end
			
			HandledProperties[PropertyName] = true
		elseif PropertyName == "MeshId" then
			if not Id then
				Id = Value
			end

			HandledProperties[PropertyName] = true
		elseif PropertyName == "CollisionFidelity" then
			Options["CollisionFidelity"] = Value
			HandledProperties[PropertyName] = true
		elseif PropertyName == "RenderFidelity" then
			Options["RenderFidelity"] = Value
			HandledProperties[PropertyName] = true
		elseif PropertyName == "FluidFidelity" then
			Options["FluidFidelity"] = Value
			HandledProperties[PropertyName] = true
		end
	end

	if not Id then
		ThrowToConsole("Attempted to deserialize a MeshPart without a MeshId property. Returning default MeshPart.")
		return Instance_new("MeshPart"), {}
	end
	
	if not next(Options) then
		Options = nil
	end
	
	-- silence the noise.
	HandledProperties["MeshContent"] = true
	
	return CreateMeshPart(Id, Options), HandledProperties
end

ReverseInstanceMap = function(Map, ParentOfInstance, DeserializeMeshPartsProperly, MainMapReference, TemporaryCacheTable, PropertyCompression)
	local ClassName = Map.C
	local Properties = Map.P
	local Children = Map.K
	local Attributes = Map.A
	local CallbackFunction = Map.Callback
	local InternalPropertyHooks = EMPTY_TABLE
	local UseInternalPropertyHooks = false -- CPU CYCLES MUST NOT GO TO WASTE!!
	local CreationHook = InstanceCreationInternalHooks[ClassName]
	local MainInstance
	
	if not PropertyCompression then
		local PotentialPropertyCompression = Map.PC
		
		if not PotentialPropertyCompression then
			return ThrowToConsole(`This version of MInstance is sadly not backwards compatible with MInstance 1.0 data due to changes in data structure to achieve more compression.`)
		else
			local ReversedPC = {}
			
			for PropertyName, PropertyId in pairs(PotentialPropertyCompression) do
				ReversedPC[PropertyId] = PropertyName
			end
			
			PropertyCompression = ReversedPC
		end
	end
	
	if CreationHook then
		if ClassName == "MeshPart" then
			if DeserializeMeshPartsProperly then
				UseInternalPropertyHooks = true
				MainInstance, InternalPropertyHooks = CreationHook(Properties, PropertyCompression)
			else
				MainInstance = Instance_new(ClassName)
			end
		else
			MainInstance = CreationHook(Properties, PropertyCompression)
		end
	else
		MainInstance = Instance_new(ClassName)
	end
	
	local SafelySetProperty = function(Property, Value)
		local Status, Error = pcall(__newindex, MainInstance, Property, Value)
		
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
		for PropertyId, Value in pairs(Properties) do
			local PropertyName = PropertyCompression[PropertyId]
			
			if not PropertyName then
				ThrowToConsole(`A property with an unknown name has been skipped due to it not being in the reverse table (PropertyCompression table). If you encounter this, data corruption might have occured to the serialized data.`)
				continue
			end
			
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
									local ChildrenList = CurrentlyPointingTo.K

									if ChildrenList then
										local IsValidMap = ChildrenList[Index]

										if IsValidMap then
											CurrentlyPointingTo = IsValidMap
										else
											ThrowToConsole(`Skipped setting property "{PropertyName}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
											break
										end
									end
								else
									local ChildrenList = MainMapReference.K

									if ChildrenList then
										local IsValidMap = ChildrenList[Index]

										if IsValidMap then
											CurrentlyPointingTo = IsValidMap
										else
											ThrowToConsole(`Skipped setting property "{PropertyName}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
											break
										end
									end
								end
							end
						end
						
						local CachedInstance = TemporaryCacheTable[CurrentlyPointingTo]
						
						if CachedInstance then
							SafelySetProperty(PropertyName, CachedInstance)
						else
							CurrentlyPointingTo.Callback = function(GotInstance)
								SafelySetProperty(PropertyName, GotInstance)
							end
						end
					else
						ThrowToConsole(`Skipped setting property "{PropertyName}" to Instance "{tostring(MainInstance)}" because it was trying to find the Instance that the property was referencing to but could not find it.`)
					end
				end
			else
				if UseInternalPropertyHooks then -- CPU CYCLES MUST NOT GO TO WASTE!!
					if InternalPropertyHooks[PropertyName] then
						continue
					end
				end
				
				SafelySetProperty(PropertyName, Value)
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
			ReverseInstanceMap(Child, MainInstance, DeserializeMeshPartsProperly, MainMapReference, TemporaryCacheTable, PropertyCompression)
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
	
	if PropertyCompressionCount > 0 then
		PropertyCompressionCount = 0
	end

	local MainMap = CreateInstanceMap(TargetInstance, IncludeDescendants, AnnoyingConsolePrints, TargetInstance, IncludeAttributes, DisallowedProperties)
	
	if PropertyCompressionCount > 0 then
		PropertyCompressionCount = 0
	end
	
	if AnnoyingConsolePrints then
		if IncludeDescendants then
			ThrowToConsole(string_format(`Finished serializing/mapping "{TargetInstance:GetFullName()}" (and {tostring(#TargetInstance:GetDescendants())} descendants) in %.4fs!`, os_clock() - StartBenchmarkTime))
		else
			ThrowToConsole(string_format(`Finished serializing/mapping "{TargetInstance:GetFullName()}" in %.4fs!`, os_clock() - StartBenchmarkTime))
		end
	end
	
	local BinaryEncoded = BufferEncoder.write(MainMap, nil, nil, true)

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
					BinaryEncoded = BufferEncoder.write(MainMap, nil, nil, true)
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

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat), nil, nil, true)
			else
				local BinaryFormat = OldCompress.DecompressNoEncoding(SerializedData)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat), nil, nil, true)
			end
		else
			if IsBase94Encoded then
				local Base94Decoded = buffer_tostring(Base94.decode(buffer_fromstring(SerializedData)))
				local BinaryFormat = NewCompress.Decompress(Base94Decoded)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat), nil, nil, true)
			else
				local BinaryFormat = NewCompress.Decompress(SerializedData)

				MainMap = BufferEncoder.read(buffer_fromstring(BinaryFormat), nil, nil, true)
			end
		end
	else
		if IsBase94Encoded then
			local BinaryBuffer = Base94.decode(buffer_fromstring(SerializedData))

			MainMap = BufferEncoder.read(BinaryBuffer, nil, nil, true)
		else
			MainMap = BufferEncoder.read(buffer_fromstring(SerializedData), nil, nil, true)
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
