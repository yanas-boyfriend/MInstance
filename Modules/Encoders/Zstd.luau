local HttpService = game:GetService("HttpService")
local Base64 = require(script.Parent.Base64)
local Zstd = {}

Zstd.Compress = function(String)
	local Compressed = buffer.fromstring(String)
	local Encoded = HttpService:JSONEncode(Compressed)
	local zB64 = Encoded:match('"zbase64":"(.-)"')
	local B64 = Encoded:match('"base64":"(.-)"')
	
	if B64 then
		return error("String passed is too short to compress.")
	end
	
	if zB64 then
		return buffer.tostring(Base64.decode(buffer.fromstring(zB64)))
	end
	
	return error("Failed to utilize Roblox's internal zstd compression algorithm by JSONEncoding a buffer. If you get this error, this feature may not be removed.")
end

Zstd.Decompress = function(String)
	local Encoded = Base64.encode(buffer.fromstring(String))
	local ReconstructedJSON = [[{"m": null, "t": "buffer", "zbase64": "]] .. buffer.tostring(Encoded) .. [["}]]
	local OriginalBuffer = HttpService:JSONDecode(ReconstructedJSON)
	
	return buffer.tostring(OriginalBuffer)
end

return Zstd
