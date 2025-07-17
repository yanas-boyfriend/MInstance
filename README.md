If I can't be a good enough partner for my girl, then I hope I can be a decent developer that contributes into making the lives of other developers easier. :frowning_face: 

MInstance is an open source, high performance, and lightweight Instance Serialization Module for Roblox Instances written in pure Luau. It has pretty much everything that you would need. Not only does it beat every other modules in terms of serialization speed, but also in serialized data compression ratio. This has only been in development for 2 days, but already has all of the features you need, while not letting a single CPU cycle go to waste.

Current Version: 1.1

---

## Why use this module?
Here are a few reasons:
- Supports majority of Roblox data types and can serialize most properties with no issues.
- Extremely fast performance!
- Supports properties with its value being set to reference to another Instance, achieving this without setting UUIDs. This allows properties such as `SelectionBox.Adornee` to perfectly work as long as it is referencing an Instance that is a descendant of the main Instance being deserialized.
- Supports MeshParts, which some other serializers fail to serialize properly. This is optional and you have to manually enable it in DeserializationSettings. (LOADS SLOW due to requiring to fetch the assets from Roblox's APIs)
- Serializes attributes.
- Instead of relying on an API dump to get properties like all other serializers do, the module will be updated to use `ReflectionService:GetPropertiesOfClass()` the moment that it is enabled, which is more futureproof than relying on the API dump.
- You have the option to encode serialized data into Base94, which allows you to store serialized data into DataStore.
- And many more!

---

## Usage
- `Minstance.SerializeInstance(TargetInstance: Instance, SerializationSettings: {})` - Serializes an Instance.

- `Minstance.DeserializeInstance(DeserializedData: string, DeserializationSettings: {})` - Decompresses or deserializes data passed into it. Please note that you have to explicitly specify if your data is compressed, if it is encoded in Base94, etc.

Settings format:
You can simply pass the Instance you want to serialize/deserialize without passing a dictionary containing the settings, and it will use the default settings. However, if you need a specific setting enabled, you will have to fill ALL of the setting inside the settings dictionary.

SerializationSettings Format:
```lua
{
	--> Setting: ValueType = DefaultValue
	IncludeDescendants: boolean = true
	CompressSerializedData: boolean = true
	EncodeInBase94: boolean = false
	AnnoyingConsolePrints: boolean = false
	UseLegacySlowCompressor: boolean = false
	IncludeAttributes: boolean = true
	DisallowedProperties: {[string]: {[string]: any} } = nil
}
```

* IncludeDescendants: Determines if the descendants of the Instance you are serializing will also be serialized.
* CompressSerializedData: Determines if the serialized data will be compressed with zstd.
* EncodeInBase94: Determines if the serialized data will be encoded in Base94, which is useful when you want to save serialized data into DataStore.
* AnnoyingConsolePrints: If this is set to `true`, it will print in the console how long it took to serialize or deserialize data every single time you call SerializeInstance or DeserializeInstance.
* UseLegacySlowCompressor: Determines if the serialized data should be compressed with the old and slow compressor (https://devforum.roblox.com/t/string-compression-zlibdeflate/755687) or use Roblox's natively compiled zstd compressor. This is absolutely NOT recommended unless the zstd compression breaks.
* IncludeAttributes: Determines if attributes of the Instance(s) should also be serialized
* DisallowedProperties: A dictionary containing the properties that you do not want to include in serialization. If there isn't any property that you want to exclude, simply leave this nil. But for example, if you want to do something like exclude property "BrickColor" of class "Part" and "MeshPart", you can pass the table below:
```lua
{
	["Part"] = {
		["BrickColor"] = true
	},
	["MeshPart"] = {
		["BrickColor"] = true
	}
}
```

---

DeserializationSettings Format:
```lua
{
	--> Setting: ValueType = DefaultValue
	IsDataCompressed: boolean = true
	IsBase94Encoded: boolean = false
	AnnoyingConsolePrints: boolean = false
	IsCompressedWithLegacyCompressor: boolean = false
	ProperlyDeserializeMeshParts: boolean = false
	ParentInstanceWhileDeserializing: Instance? = nil
}
```

* IsDataCompressed: Pass `true` if your serialized data is compressed, aka if `CompressSerializedData` was set to true when you serialized your Instance.
* IsBase94Encoded: Pass `true` if your serialized data is encoded in Base94, aka if `CompressSerializedData` was set to true when you serialized your Instance.
* AnnoyingConsolePrints: If this is set to `true`, it will print in the console how long it took to serialize or deserialize data every single time you call SerializeInstance or DeserializeInstance.
* IsCompressedWithLegacyCompressor: Pass `true` if your serialized data was compressed with the old and slow zlib compression algorithm, aka if `UseLegacySlowCompressor` was set to true when you serialized your Instance.
* ProperlyDeserializeMeshParts: If this is set to `true`, MeshParts will be properly deserialized and loaded. However, this takes VERY LONG, due to needing to fetch the mesh asset from Roblox's APIs. This is NOT recommended to be enabled unless you really want to properly deserialize MeshParts.
* ParentInstanceWhileDeserializing: If an Instance is passed to this, it will parent the main Instance you are deserializing to the Instance passed as `ParentInstanceWhileDeserializing` BEFORE it deserializes any of its children. Leave this `nil` if you do not need that.

---

Example code usage:
```lua
local MInstance = require(path.to.Minstance)
local TargetInstanceToSerialize = workspace.Part

local SerializationSettings = {
	IncludeDescendants = true,
	CompressSerializedData = true,
	EncodeInBase94 = false,
	AnnoyingConsolePrints = true,
	UseLegacySlowCompressor = false,
	IncludeAttributes = true,
	DisallowedProperties = nil
}

local DeserializationSettings = {
	IsDataCompressed = true,
	IsBase94Encoded = false,
	AnnoyingConsolePrints = false,
	IsCompressedWithLegacyCompressor = false,
	ProperlyDeserializeMeshParts = false,
	ParentInstanceWhileDeserializing = nil
}

local Serialized = MInstance.SerializeInstance(TargetInstanceToSerialize, SerializationSettings)
local Deserialized = MInstance.DeserializeInstance(Serialized, DeserializationSettings)

print(Deserialized)
```

---

## More Information
For more information such as benchmarks, you can refer to the Roblox DevForum post about MInstance:
https://devforum.roblox.com/t/an-ultra-optimized-instance-serializer-that-can-serialize-40000-instances-and-compress-it-into-a-100k-character-string-in-only-07s/3818154
