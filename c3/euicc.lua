-- SGP.22 ES10c DER tags checked against lpac v2.3.0 euicc/es10c.c.
local modem = require("modem")
local M = {}
local aid = "A0000005591010FFFFFFFF8900000100"

local function unhex(s)
    assert(#s % 2 == 0 and s:match('^%x+$'), "Invalid APDU hex")
    return (s:gsub('..', function(v) return string.char(tonumber(v, 16)) end))
end
local function hex(s)
    return (s:gsub('.', function(v) return string.format('%02X', v:byte()) end))
end

local function tlvs(s)
    local pos = 1
    return function()
        if pos > #s then return end
        local first = s:byte(pos); local tag = first; pos = pos + 1
        if first & 31 == 31 then
            repeat
                local b = assert(s:byte(pos), "Truncated DER tag")
                tag = tag * 256 + b; pos = pos + 1
            until b & 128 == 0
        end
        local length = assert(s:byte(pos), "Truncated DER length"); pos = pos + 1
        if length & 128 ~= 0 then
            local count = length & 127
            assert(count > 0, "Indefinite DER length")
            length = 0
            for _ = 1, count do length = length * 256 + assert(s:byte(pos)); pos = pos + 1 end
        end
        assert(pos + length - 1 <= #s, "Truncated DER value")
        local value = s:sub(pos, pos + length - 1); pos = pos + length
        return tag, value
    end
end
local function field(s, wanted)
    for tag, value in tlvs(s) do if tag == wanted then return value end end
    error(string.format("Missing DER tag %X", wanted), 0)
end
local function wrap(tag, value)
    local n = #value
    local size = n < 128 and string.char(n) or
        (n < 256 and string.char(129, n) or string.char(130, n >> 8, n & 255))
    return unhex(tag) .. size .. value
end

function M.open(app)
    local lines = modem.command('AT+CCHO="' .. (app or aid) .. '"', 15000)
    for _, line in ipairs(lines) do
        local channel = tonumber(line:match('^%+CCHO:%s*(%d+)$') or line:match('^(%d+)$'))
        if channel then return channel end
    end
    error("CCHO did not return a channel", 0)
end
function M.close(channel) modem.command("AT+CCHC=" .. channel, 10000); return true end
function M.transmit(channel, apdu)
    unhex(apdu)
    local lines = modem.command(string.format('AT+CGLA=%d,%d,"%s"', channel, #apdu, apdu), 30000)
    for _, line in ipairs(lines) do
        local value = line:match('^%+CGLA:%s*%d+,%s*"?(%x+)')
        if value then return value end
    end
    error("CGLA did not return an APDU", 0)
end

local function exchange_stream(channel, size, read)
    assert(channel >= 1 and channel <= 3, "Local ES10c supports channels 1..3")
    local chunks, sw = {}, nil
    for pos = 1, size, 255 do
        local piece = read(math.min(255, size - pos + 1))
        local apdu = string.char(0x80 | channel, 0xE2,
            pos + 254 >= size and 0x91 or 0x11, (pos - 1) // 255, #piece) .. piece
        repeat
            local response = unhex(M.transmit(channel, hex(apdu)))
            chunks[#chunks + 1] = response:sub(1, -3)
            local sw1, sw2 = response:byte(-2, -1)
            sw = hex(response:sub(-2))
            if sw1 == 0x61 then
                apdu = string.char(channel, 0xC0, 0, 0, sw2)
            else
                assert(sw == "9000" or sw1 == 0x91, "Card status " .. sw)
                break
            end
        until false
    end
    return table.concat(chunks), sw
end

local function exchange(channel, body)
    local offset = 1
    return exchange_stream(channel, #body, function(n)
        local piece = body:sub(offset, offset + n - 1); offset = offset + n
        return piece
    end)
end

local function session(fn)
    return modem.exclusive(function()
        local channel = M.open()
        local ok, result = pcall(fn, channel)
        local closed, close_error = pcall(M.close, channel)
        if not ok then error(result, 0) end
        if not closed then result.close_error = tostring(close_error) end
        return result
    end)
end

function M.info()
    return session(function(ch)
        local raw, sw = exchange(ch, unhex("BF3E035C015A"))
        local eid = hex(field(field(raw, 0xBF3E), 0x5A))
        raw = exchange(ch, unhex('BF2200'))
        local memory = {}
        local names = {[0x81]='installed_applications', [0x82]='free_nonvolatile', [0x83]='free_volatile'}
        for tag, value in tlvs(field(field(raw, 0xBF22), 0x84)) do
            if names[tag] then
                local n = 0
                for i = 1, #value do n = n * 256 + value:byte(i) end
                memory[names[tag]] = n
            end
        end
        return {eid=eid, memory=memory, status_word=sw}
    end)
end
function M.list()
    return session(function(ch)
        local raw, sw = exchange(ch, unhex("BF2D00")); local profiles = {}
        for tag, value in tlvs(field(field(raw, 0xBF2D), 0xA0)) do
            if tag == 0xE3 then
                local p = {}
                for t, v in tlvs(value) do
                    if t == 0x5A then
                        p.iccid = hex(v):gsub('(.)(.)', '%2%1'):gsub('F+$', '')
                    elseif t == 0x9F70 then p.state = v:byte()
                    elseif t == 0x90 then p.nickname = v
                    elseif t == 0x91 then p.provider = v
                    elseif t == 0x92 then p.name = v end
                end
                profiles[#profiles + 1] = p
            end
        end
        return {profiles = profiles, status_word = sw}
    end)
end
function M.change(operation, iccid)
    local tags = {enable = "BF31", disable = "BF32", delete = "BF33"}
    local tag = assert(tags[operation], "Unknown profile operation")
    assert(type(iccid) == "string" and iccid:match('^%d+$') and #iccid >= 19 and #iccid <= 20,
        "Full 19/20 digit ICCID required")
    return modem.exclusive(function()
        local found
        for _, p in ipairs(M.list().profiles) do if p.iccid == iccid then found = p end end
        assert(found, "Profile not found")
        if operation == "delete" then assert(found.state == 0, "Disable profile before deletion") end
        local bcd = (iccid .. (#iccid % 2 == 1 and 'F' or '')):gsub('(.)(.)', '%2%1')
        local identifier = wrap("5A", unhex(bcd))
        local body = operation == "delete" and identifier or wrap("A0", identifier) .. unhex("8101FF")
        local result = session(function(ch)
            local raw, sw = exchange(ch, wrap(tag, body))
            local code = field(field(raw, tonumber(tag, 16)), 0x80):byte()
            assert(code == 0, "ES10c result " .. code)
            return {operation = operation, iccid = iccid, result = code, status_word = sw}
        end)
        -- This AIR firmware needs a full restart after profile REFRESH.
        if operation ~= "delete" then modem.restart() end
        result.profiles = M.list().profiles
        return result
    end)
end
function M.nickname(iccid, value)
    assert(type(iccid)=='string' and iccid:match('^%d+$') and (#iccid==19 or #iccid==20),'Full ICCID required')
    assert(type(value)=='string' and utf8.len(value) and utf8.len(value)<=64,'名称和标签合计最多 64 个字符')
    local bcd=(iccid..(#iccid%2==1 and 'F' or '')):gsub('(.)(.)','%2%1')
    return session(function(ch)
        local raw=exchange(ch,wrap('BF29',wrap('5A',unhex(bcd))..wrap('90',value)))
        local code=field(field(raw,0xBF29),0x80):byte()
        assert(code==0,'修改名称/标签失败：'..code)
        return {saved=true}
    end)
end

M.exchange, M.session, M.exchange_stream = exchange, session, exchange_stream
M.hex, M.unhex, M.field, M.wrap, M.tlvs = hex, unhex, field, wrap, tlvs
return M
