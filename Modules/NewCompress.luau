local Compressor = {}
local ZStd = require(script.Parent.Encoders.Zstd)

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

		if CacheCount > 100 then
			local Key = GetFirstKeyOfDict(self)

			rawset(self, Key, nil)
		end

		rawset(self, New, Index)
	end
})

Compressor.Compress = function(String)
	local Cached = Cache[String]

	if Cached then
		return Cached
	end

	local Compressed = ZStd.Compress(String)

	Cache[String] = Compressed

	return Compressed
end

Compressor.Decompress = function(String)
	local Cached = Cache[String]

	if Cached then
		return Cached
	end

	local Decompressed = ZStd.Decompress(String)

	Cache[String] = Decompressed

	return Decompressed
end

return Compressor
