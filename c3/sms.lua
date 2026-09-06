-- SMS-DELIVER decoding: 3GPP TS 23.040 / TS 23.038.
local M = {received = 0, pending = {}, recent = {}}
local multipart = {}
local special = {[0]='@','£','$','¥','è','é','ù','ì','ò','Ç','\n','Ø','ø','\r','Å','å',
    'Δ','_','Φ','Γ','Λ','Ω','Π','Ψ','Σ','Θ','Ξ','', 'Æ','æ','ß','É',
    [36]='¤',[64]='¡',[91]='Ä',[92]='Ö',[93]='Ñ',[94]='Ü',[95]='§',[96]='¿',
    [123]='ä',[124]='ö',[125]='ñ',[126]='ü',[127]='à'}
local extension = {[10]='\f',[20]='^',[40]='{',[41]='}',[47]='\\',[60]='[',[61]='~',[62]=']',[64]='|',[101]='€'}
local function gsm7(data, count, bit)
    local out, escaped = {}, false
    for _ = 1, count do
        local pos, shift = bit // 8 + 1, bit % 8
        local v = ((data:byte(pos) | ((data:byte(pos + 1) or 0) << 8)) >> shift) & 127
        if escaped then out[#out + 1] = extension[v] or '�'; escaped = false
        elseif v == 27 then escaped = true
        else out[#out + 1] = special[v] or string.char(v) end
        bit = bit + 7
    end
    return table.concat(out)
end
local function semi(data)
    return (data:gsub('.', function(c)
        local b = c:byte(); return string.format('%X%X', b & 15, b >> 4)
    end))
end
local function ucs2(data)
    local out, pos = {}, 1
    while pos <= #data do
        local cp = (data:byte(pos) << 8) | data:byte(pos + 1); pos = pos + 2
        if cp >= 0xD800 and cp <= 0xDBFF then
            local low = (data:byte(pos) << 8) | data:byte(pos + 1); pos = pos + 2
            cp = 0x10000 + (cp - 0xD800) * 1024 + low - 0xDC00
        end
        out[#out + 1] = utf8.char(cp)
    end
    return table.concat(out)
end
function M.decode(pdu)
    local data = pdu:gsub('..', function(v) return string.char(tonumber(v, 16)) end)
    local pos = 2 + data:byte(1)
    local flags = data:byte(pos); pos = pos + 1
    assert(flags & 3 == 0, "Not SMS-DELIVER")
    local digits, toa = data:byte(pos, pos + 1); pos = pos + 2
    local bytes = (digits + 1) // 2
    local address = data:sub(pos, pos + bytes - 1); pos = pos + bytes
    local sender
    if toa & 0x70 == 0x50 then sender = gsm7(address, digits * 4 // 7, 0)
    else sender = (toa & 0x70 == 0x10 and '+' or '') .. semi(address):sub(1, digits) end
    local dcs = data:byte(pos + 1); pos = pos + 2
    local stamp = data:sub(pos, pos + 6); pos = pos + 7
    local stamp_digits = semi(stamp:sub(1, 6))
    local zone = stamp:byte(7)
    local zone_quarters = (zone & 7) * 10 + (zone >> 4)
    local timestamp = string.format('20%s-%s-%sT%s:%s:%s%s%02d:%02d',
        stamp_digits:sub(1,2), stamp_digits:sub(3,4), stamp_digits:sub(5,6),
        stamp_digits:sub(7,8), stamp_digits:sub(9,10), stamp_digits:sub(11,12),
        zone & 8 ~= 0 and '-' or '+', zone_quarters // 4, zone_quarters % 4 * 15)
    local length = data:byte(pos); pos = pos + 1
    local ud, header, ref, total, part = data:sub(pos), 0, nil, nil, nil
    if flags & 64 ~= 0 then
        header = ud:byte(1) + 1
        local i = 2
        while i <= header do
            local kind, size = ud:byte(i, i + 1)
            if kind == 0 and size == 3 then ref, total, part = ud:byte(i + 2, i + 4)
            elseif kind == 8 and size == 4 then
                ref = ud:byte(i + 2) * 256 + ud:byte(i + 3)
                total, part = ud:byte(i + 4, i + 5)
            end
            i = i + 2 + size
        end
    end
    local alphabet = dcs & 12
    if dcs & 0xF0 == 0xE0 then alphabet = 8
    elseif dcs & 0xF0 == 0xF0 then alphabet = dcs & 4 end
    local content
    if alphabet == 8 then content = ucs2(ud:sub(header + 1, length))
    elseif alphabet == 0 then
        local skip = (header * 8 + 6) // 7
        content = gsm7(ud, length - skip, skip * 7)
    else content = nil end
    return {sender = sender, timestamp = timestamp, text = content, pdu = pdu,
        reference = ref, total = total, part = part, dcs = dcs}
end
function M.accept(pdu)
    local message = M.decode(pdu)
    if message.total and message.total > 1 then
        local key = message.sender .. ':' .. message.reference .. ':' .. message.total
        local group = multipart[key] or {parts = {}, pdus = {}}
        multipart[key] = group
        group.parts[message.part], group.pdus[message.part] = message.text or '', message.pdu
        for i = 1, message.total do if not group.pdus[i] then return end end
        message.text = table.concat(group.parts)
        message.pdu = nil; message.pdus = group.pdus
        multipart[key] = nil
    end
    M.received = M.received + 1
    message.id = tostring(os.time()) .. '-' .. M.received
    M.recent[#M.recent + 1] = message
    if #M.recent > 4 then table.remove(M.recent, 1) end
    if #M.pending >= 8 then
        log.error('sms', 'Pending queue full; oldest message retained in recent host records if delivered')
        table.remove(M.pending, 1)
    end
    M.pending[#M.pending + 1] = message
    return message
end
return M
