--!native
--!optimize 2

-- written by @WalletOverflow on roblox

-- i wonder if declaring a variable pointing to the functions directly would make any difference or if luau automatically optimizes it this way...
-- well at least now we are no longer indexing to the tables like the buffer table during run time :smirk:
-- i love 2 ms optimizations!!
local string_char = string.char
local string_byte = string.byte
local table_concat = table.concat
local math_floor = math.floor
local bit32_lshift = bit32.lshift
local bit32_rshift = bit32.rshift
local bit32_bor = bit32.bor
local bit32_band = bit32.band
local buffer_create = buffer.create
local buffer_len = buffer.len
local buffer_readu8 = buffer.readu8
local buffer_writeu8 = buffer.writeu8

local alphabet = (function()
	local chars = {}

	for code = 32, 127 do
		if code ~= 34 and code ~= 92 then
			chars[#chars + 1] = string_char(code)
		end
	end

	return table_concat(chars)
end)()

local lookupValueToCharacter = buffer_create(94)
local lookupCharacterToValue = buffer_create(256)
local powersOf94 = {94^4, 94^3, 94^2, 94^1, 1}

for i = 0, 93 do
	local charCode = string_byte(alphabet, i + 1)

	buffer_writeu8(lookupValueToCharacter, i, charCode)
	buffer_writeu8(lookupCharacterToValue, charCode, i)
end

local function encode(input: buffer): buffer
	local inLen = buffer_len(input)
	local full = math_floor(inLen / 4)
	local rem	= inLen % 4
	local outLen = full * 5 + (rem > 0 and rem + 1 or 0)
	local out = buffer_create(outLen)

	-- full 4-byte chunks
	for ci = 0, full - 1 do
		local baseIn = ci * 4
		local chunk = bit32_bor(
			bit32_lshift(buffer_readu8(input, baseIn), 24),
			bit32_lshift(buffer_readu8(input, baseIn + 1), 16),
			bit32_lshift(buffer_readu8(input, baseIn + 2), 8),
			buffer_readu8(input, baseIn + 3)
		)

		-- decompose into five 0–93 digits and write directly to the buffer,
		-- big-endian (most significant digit first)
		local baseOut = ci * 5
		local tempChunk = chunk
		for i = 4, 0, -1 do
			local digit = tempChunk % 94
			tempChunk = math_floor(tempChunk / 94)
			buffer_writeu8(out, baseOut + i, buffer_readu8(lookupValueToCharacter, digit))
		end
	end

	if rem > 0 then
		local baseIn = full * 4
		local chunk = 0

		if rem >= 1 then chunk = bit32_bor(bit32_lshift(chunk, 8), buffer_readu8(input, baseIn)) end
		if rem >= 2 then chunk = bit32_bor(bit32_lshift(chunk, 8), buffer_readu8(input, baseIn + 1)) end
		if rem >= 3 then chunk = bit32_bor(bit32_lshift(chunk, 8), buffer_readu8(input, baseIn + 2)) end

		local baseOut = full * 5
		local requiredChars = rem + 1

		for i = requiredChars - 1, 0, -1 do
			local digit = chunk % 94
			chunk = math_floor(chunk / 94)
			buffer_writeu8(out, baseOut + i, buffer_readu8(lookupValueToCharacter, digit))
		end
	end

	return out
end

local function decode(input: buffer): buffer
	local inLen = buffer_len(input)
	local full = math_floor(inLen / 5)
	local rem	= inLen % 5
	if rem == 1 then rem = 0 end -- 1-char tail is invalid padding
	local outLen = full * 4 + (rem > 0 and rem - 1 or 0)
	local out = buffer_create(outLen)

	-- full 5-char chunks
	for ci = 0, full - 1 do
		local baseIn = ci * 5
		local value = 0

		-- reconstruct number using horner's method for efficiency :smirk:
		for i = 0, 4 do
			local c = buffer_readu8(input, baseIn + i)
			local d = buffer_readu8(lookupCharacterToValue, c)
			value = value * 94 + d
		end

		-- extract b1..b4
		local baseOut = ci * 4
		for i = 0, 3 do
			local shift = 24 - (i * 8)
			local byte = bit32_band(bit32_rshift(value, shift), 0xFF)
			buffer_writeu8(out, baseOut + i, byte)
		end
	end

	-- partial tail
	if rem > 0 then
		local baseIn = full * 5
		local value = 0

		-- reconstruct the number from the big-endian digits
		for i = 0, rem - 1 do
			local c = buffer_readu8(input, baseIn + i)
			local d = buffer_readu8(lookupCharacterToValue, c)
			value = value * 94 + d
		end

		local requiredBytes = rem - 1
		local baseOut = full * 4

		-- extract the original bytes from the reconstructed number, big-endian
		for i = requiredBytes - 1, 0, -1 do
			local byte = bit32_band(value, 0xFF)
			value = bit32_rshift(value, 8)
			buffer_writeu8(out, baseOut + i, byte)
		end
	end

	return out
end

return {
	encode = encode,
	decode = decode,
}
