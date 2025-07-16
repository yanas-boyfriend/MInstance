local Compressor = {}
local Base94 = require(script.Parent.Encoders.Base94)
local ZLib = require(script.Parent.Encoders.Zlib)

local ENABLE_DATA_COMPRESSION = true
local ZLIB_COMPRESSION_LEVEL = 9
local MAX_CACHED_VALUES = 100

local GetKeyCount = function(Dictionary)
	local Count = 0
	
	for _ in pairs(Dictionary) do
		Count += 1
	end
	
	return Count
end

local GetFirstKeyOfDict = function(Dictionary)
	for Key in pairs(Dictionary) do
		return Key
	end
end

local Cache = setmetatable({}, {
	__newindex = function(self, New, Index)
		local CacheCount = GetKeyCount(self)
		
		if CacheCount > MAX_CACHED_VALUES then
			local Key = GetFirstKeyOfDict(self)
			
			rawset(self, Key, nil)
		end
		
		rawset(self, New, Index)
	end
})

local Cache2 = setmetatable({}, {
	__newindex = function(self, New, Index)
		local CacheCount = GetKeyCount(self)

		if CacheCount > MAX_CACHED_VALUES then
			local Key = GetFirstKeyOfDict(self)

			rawset(self, Key, nil)
		end

		rawset(self, New, Index)
	end
})

local ZLibCompress = ZLib.Zlib.Compress
local ZLibDecompress = ZLib.Zlib.Decompress
local B94Encode = Base94.encode
local B94Decode = Base94.decode

Compressor.Compress = function(String)
	if not ENABLE_DATA_COMPRESSION then
		return String
	end
	
	local Cached = Cache[String]
	
	if Cached then
		return Cached
	end
	
	local ZLibCompressed
	
	if #String > 100 then
		ZLibCompressed = ZLibCompress(String, {
			level = ZLIB_COMPRESSION_LEVEL
		})
	else
		ZLibCompressed = String
	end
	
	local EncodedBuffer = B94Encode(buffer.fromstring(ZLibCompressed))
	local B94Encoded = buffer.tostring(EncodedBuffer)
	
	Cache[String] = B94Encoded
	
	return B94Encoded
end

Compressor.Decompress = function(String)
	if not ENABLE_DATA_COMPRESSION then
		return String
	end
	
	local Cached = Cache[String]

	if Cached then
		return Cached
	end

	local DecodedBuffer = B94Decode(buffer.fromstring(String))
	local B94Decoded = buffer.tostring(DecodedBuffer)
	local Status, ZLibDecompressed = pcall(ZLibDecompress, B94Decoded)
	
	if Status and ZLibDecompressed ~= nil then
		Cache[String] = ZLibDecompressed
		
		return ZLibDecompressed
	end
	
	Cache[String] = B94Decoded
	
	return B94Decoded
end

Compressor.CompressNoEncoding = function(String)
	if not ENABLE_DATA_COMPRESSION then
		return String
	end
	
	local Cached = Cache2[String]
	
	if Cached then
		return Cached
	end
	
	local ZLibCompressed = ZLibCompress(String, {
		level = ZLIB_COMPRESSION_LEVEL
	})
	
	Cache2[String] = ZLibCompressed
	
	return ZLibCompressed
end

Compressor.DecompressNoEncoding = function(String)
	if not ENABLE_DATA_COMPRESSION then
		return String
	end
	
	local Cached = Cache2[String]

	if Cached then
		return Cached
	end
	
	local Status, ZLibDecompressed = pcall(ZLibDecompress, String)

	if Status and ZLibDecompressed ~= nil then
		Cache2[String] = ZLibDecompressed

		return ZLibDecompressed
	end
end

return Compressor
