-- Read-only status and log stream on a separate listener from HTTP.
local sys = require('sys')
local lpa = require('lpa')
local link = require('device_status')
local M = {state={connected=false}}
link.websocket = M.state
local events, seconds = {}, 0
local function callback(_, event, value)
    events[event] = value or 0
    sys.publish('PUSH_SOCKET')
end
local function wait(event, timeout)
    local deadline = timeout and seconds + math.ceil(timeout / 1000)
    while events[event] == nil do
        assert(events[socket.CLOSED] == nil, 'Connection closed')
        assert(not deadline or seconds < deadline, 'Socket timeout')
        sys.waitUntil('PUSH_SOCKET', timeout)
    end
    local value = events[event]; events[event] = nil
    assert(value == 0, 'Socket error')
end
local function send(ctrl, data)
    for pos = 1, #data, 512 do
        events[socket.TX_OK] = nil
        local ok, full, done = socket.tx(ctrl, data:sub(pos, pos + 511))
        assert(ok and not full, 'Transmit failed')
        if not done then wait(socket.TX_OK, 5000) end
    end
end
local function frame(ctrl, opcode, data)
    local size = #data
    send(ctrl, string.char(0x80 | opcode) .. (size < 126 and string.char(size) or string.pack('>BI2', 126, size)))
    send(ctrl, data)
end
local function receive(ctrl, buff)
    assert(socket.rx(ctrl, buff, 0, 512), 'Receive failed')
    local data = buff:query(0, buff:used()) or ''; buff:del()
    return data
end
local function reject(ctrl, code)
    send(ctrl, 'HTTP/1.1 ' .. code .. '\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
end
local function handshake(ctrl, buff)
    local request, split, deadline = '', nil, seconds + 5
    repeat
        request = request .. receive(ctrl, buff)
        if #request > 2048 then reject(ctrl, '431 Request Header Fields Too Large'); return end
        split = request:find('\r\n\r\n', 1, true)
        if split then break end
        assert(seconds < deadline, 'Handshake timeout')
        local ok, available = socket.wait(ctrl); assert(ok, 'Connection closed')
        if not available then wait(socket.EVENT, 5000) end
    until false
    if not request:match('^GET /ws HTTP/1%.1\r\n') then reject(ctrl, '400 Bad Request'); return end
    local headers = {}
    for name, value in request:sub(1, split + 1):gmatch('\r\n([^:%s]+):[ \t]*([^\r]*)') do
        name = name:lower()
        if headers[name] then reject(ctrl, '400 Bad Request'); return end
        headers[name] = value:gsub('[ \t]+$', '')
    end
    local key = headers['sec-websocket-key'] or ''
    local connection = ',' .. (headers.connection or ''):lower():gsub('%s', '') .. ','
    if not headers.host or (headers.upgrade or ''):lower() ~= 'websocket' or not connection:find(',upgrade,', 1, true)
        or headers['sec-websocket-version'] ~= '13' or #key ~= 24 or not key:match('^[%w+/]+=+$')
        or #crypto.base64_decode(key) ~= 16 then reject(ctrl, '400 Bad Request'); return end
    local token = require('config').access_key
    local protocol = 'sim.' .. crypto.base64_encode(token):gsub('%+', '-'):gsub('/', '_'):gsub('=', '')
    if token == '' or headers['sec-websocket-protocol'] ~= protocol then reject(ctrl, '401 Unauthorized'); return end
    local digest = crypto.sha1(key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'):gsub('..', function(hex) return string.char(tonumber(hex, 16)) end)
    send(ctrl, 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' ..
        crypto.base64_encode(digest) .. '\r\nSec-WebSocket-Protocol: ' .. protocol .. '\r\n\r\n')
    return request:sub(split + 4)
end
local function controls(ctrl, pending)
    local pong = false
    while #pending >= 2 do
        local first, second = pending:byte(1, 2)
        local opcode, size = first & 15, second & 127
        if first & 0xF0 ~= 0x80 or second & 0x80 == 0 or size > 125 or (opcode ~= 8 and opcode ~= 9 and opcode ~= 10) then
            frame(ctrl, 8, string.pack('>I2', 1002)); return nil
        end
        if #pending < size + 6 then break end
        local mask, body = {pending:byte(3, 6)}, {}
        for i = 1, size do body[i] = string.char(pending:byte(i + 6) ~ mask[(i - 1) % 4 + 1]) end
        local payload = table.concat(body)
        pending = pending:sub(size + 7)
        if opcode == 8 then
            frame(ctrl, 8, size == 1 and string.pack('>I2', 1002) or ''); return nil
        elseif opcode == 9 then frame(ctrl, 10, payload)
        elseif payload == 'sim' then pong = true end
    end
    return pending, pong
end
local function serve(ctrl, buff)
    local pending = handshake(ctrl, buff)
    if not pending then return end
    M.state.connected=true; M.state.error=nil
    local due, ping_at, pong_at = 0, seconds + 10, seconds
    local offset, generation, revision = 0, nil, nil
    while true do
        local pong
        pending, pong = controls(ctrl, pending .. receive(ctrl, buff))
        if not pending then return end
        if pong then pong_at = seconds end
        assert(seconds - pong_at < 30, 'Heartbeat timeout')
        if seconds >= ping_at then frame(ctrl, 9, 'sim'); ping_at = seconds + 10 end
        if seconds >= due then
            frame(ctrl, 1, json.encode({type='status', data=link.status()}))
            due = seconds + 2
        end
        local current = lpa.job.log_generation or 0
        if current ~= generation then
            frame(ctrl, 1, '{"type":"log-reset"}')
            generation, offset, revision = current, 0, nil
        end
        -- Close the file before yielding to a socket write or the next download.
        for _ = 1, 4 do
            local current_revision = lpa.job.log_revision or 0
            if revision == current_revision then break end
            if (lpa.job.log_generation or 0) ~= generation then break end
            local f = io.open('/lpa-download.log', 'rb')
            if not f then revision = current_revision; break end
            f:seek('set', offset)
            local chunk = f:read(512); f:close()
            if not chunk then revision = current_revision; break end
            frame(ctrl, 2, chunk); offset = offset + #chunk
        end
        local ok, available = socket.wait(ctrl); assert(ok, 'Connection closed')
        if not available then sys.waitUntil('PUSH_SOCKET', 250) else sys.wait(1) end
        assert(events[socket.CLOSED] == nil, 'Connection closed')
    end
end
function M.start()
    sys.timerLoopStart(function() seconds = seconds + 1 end, 1000)
    sys.taskInit(function()
        while not socket.adapter(socket.LWIP_STA) do sys.wait(1000) end
        local server = assert(socket.create(socket.LWIP_STA, callback))
        assert(socket.config(server, 81))
        local ok, up = socket.linkup(server); assert(ok)
        if not up then wait(socket.LINK, 10000) end
        while true do
            events = {}
            local listening, connected = socket.listen(server); assert(listening)
            if not connected then wait(socket.ON_LINE) end
            local accepted, child = socket.accept(server, callback)
            if accepted then
                local client, buff = child or server, zbuff.create(512)
                local success, err = pcall(serve, client, buff)
                buff:free()
                M.state.connected=false
                if not success then M.state.error=tostring(err); log.warn('push', tostring(err)) end
                local closing, closed = socket.discon(client)
                if closing and not closed then pcall(wait, socket.CLOSED, 5000) end
                socket.close(client)
                if child then socket.release(child) end
                collectgarbage('collect')
            end
        end
    end)
end
return M
