-- Single active HTTP client; static page streams from Flash in 1 KiB chunks.
-- HTTP/1.0 close-delimited responses let clients finish after discon closes the
-- SDK single-client listener, preventing the next connection being closed with it.
-- This SDK callback passes lightuserdata, which is not equal to create() userdata.
-- One active client shares its event table without indexing by userdata.
-- Socket API checked against LuatOS commit da2373564e282b420ffcdb6080323bffbd36f947 (V1007, July 2024).
local sys = require('sys')
local config = require('config')
local settings = require('settings')
local link, euicc, sms, lpa
local setup_mode = false
local M = {}
local events = {}
local function callback(ctrl, event, param)
    events[event] = param or 0
    sys.publish('WEB_SOCKET')
end
local function wait(ctrl, event, timeout)
    if timeout == 0 then timeout = nil end
    local e = events
    while e[event] == nil do
        if e[socket.CLOSED] ~= nil then error('Connection closed', 0) end
        assert(sys.waitUntil('WEB_SOCKET', timeout), 'Socket timeout')
    end
    local value = e[event]; e[event] = nil
    assert(value == 0, 'Socket error ' .. tostring(value))
end
local function send(ctrl, data)
    for pos = 1, #data, 1024 do
        local piece = data:sub(pos, pos + 1023)
        events[socket.TX_OK] = nil
        local ok, full, done = socket.tx(ctrl, piece)
        assert(ok and not full, 'Socket transmit failed')
        if not done then wait(ctrl, socket.TX_OK, 5000) end
    end
end
local function response(ctrl, code, body, kind, extra)
    send(ctrl, 'HTTP/1.0 ' .. code .. '\r\nContent-Type: ' .. (kind or 'application/json; charset=utf-8') ..
        '\r\nConnection: close\r\nCache-Control: no-store\r\n' .. (extra or '') .. '\r\n')
    send(ctrl, body)
end
local function serve(ctrl)
    local buff, request = zbuff.create(1024), ''
    local split, wanted
    repeat
        local ok = socket.rx(ctrl, buff)
        assert(ok, 'Receive failed')
        if buff:used() > 0 then
            request = request .. buff:query(0, buff:used()); buff:del()
            assert(#request <= 4096, 'Request exceeds 4 KiB')
            split = request:find('\r\n\r\n', 1, true)
            if split then wanted = split + 3 + (tonumber(request:sub(1,split):lower():match('content%-length:%s*(%d+)')) or 0) end
        end
        if wanted and #request >= wanted then break end
        local good, available = socket.wait(ctrl)
        assert(good, 'Connection closed')
        if not available then wait(ctrl, socket.EVENT, 5000) end
    until false
    buff:free()
    local method, path = request:match('^(%u+) ([^ ]+)')
    if method == 'GET' and path == '/' then
        local f = assert(io.open(setup_mode and '/luadb/setup.html.gz' or '/luadb/panel.html.gz', 'rb'), 'Page file missing')
        send(ctrl, 'HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n')
        while true do local chunk=f:read(1024); if not chunk then break end; send(ctrl, chunk) end
        f:close(); return
    end
    if setup_mode then
        if method == 'GET' and path == '/api/provision' then
            response(ctrl, '200 OK', json.encode({ssid=config.wifi.ssid,has_key=config.access_key~=''}))
        elseif method == 'POST' and path == '/api/provision' then
            local ok,value=pcall(function()
                local kind=request:sub(1,split):lower():match('\r\ncontent%-type:%s*([^\r]+)') or ''
                assert(kind:match('^application/json'), '请求需要 JSON 格式')
                return settings.provision(json.decode(request:sub(split+4,wanted)))
            end)
            response(ctrl,ok and '200 OK' or '400 Bad Request',json.encode(ok and value or {error=tostring(value)}))
            if ok then sys.timerStart(rtos.reboot,1000) end
        else response(ctrl, '404 Not Found', '{"error":"配网模式"}') end
        return
    end
    local authorization = request:match('\r\n[Aa]uthorization:%s*([^\r]+)')
    if config.access_key == '' or authorization ~= 'Bearer ' .. config.access_key then
        response(ctrl, '401 Unauthorized', '{"error":"请输入面板访问密钥"}'); return
    end
    if method == 'GET' and path == '/api/download-log' then
        local f=io.open('/lpa-download.log','rb')
        if not f then response(ctrl,'200 OK','尚无下卡日志','text/plain; charset=utf-8'); return end
        send(ctrl,'HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n')
        local ok,err=pcall(function()
            while true do local chunk=f:read(512); if not chunk then break end; send(ctrl,chunk) end
        end)
        f:close()
        if not ok then error(err,0) end
        return
    end
    local body = request:sub(split + 4, wanted)
    local ok, value = pcall(function()
        if method == 'GET' and path == '/api/status' then return link.status() end
        if method == 'POST' and path == '/api/modem' then
            sys.publish('RADIO_REFRESH')
            return {requested=true}
        end
        if method == 'POST' and path == '/api/network' then return lpa.probe(json.decode(body).host) end
        if method == 'GET' and path == '/api/download' then return lpa.job end
        if method == 'POST' and path == '/api/download' then return lpa.start(json.decode(body)) end
        if path == '/api/info' or path == '/api/profiles' or path == '/api/profile' or path == '/api/nickname' or path == '/api/notifications' or path == '/api/modem-reboot' then
            assert(lpa.job.state ~= 'running' and lpa.notification_job.state ~= 'running', 'Card task is running')
        end
        if method == 'GET' and path == '/api/notification-status' then return lpa.notification_job end
        if method == 'GET' and path == '/api/notifications' then
            local done,result=pcall(function() return require('notifications').list() end)
            unload('notifications')
            if not done then error(result,0) end
            return result
        end
        if method == 'POST' and path == '/api/notifications' then return lpa.notify(json.decode(body).id) end
        if method == 'POST' and path == '/api/nickname' then
            local data=json.decode(body)
            return euicc.nickname(data.iccid,data.nickname)
        end
        if method == 'GET' and path == '/api/info' then return euicc.info() end
        if method == 'GET' and path == '/api/profiles' then return euicc.list() end
        if method == 'GET' and path == '/api/sms' then return {messages=sms.recent} end
        if method == 'GET' and path == '/api/settings' then return settings.public() end
        if method == 'POST' and path == '/api/settings' then return settings.save(json.decode(body)) end
        if method == 'POST' and path == '/api/profile' then
            local data = json.decode(body)
            local result=euicc.change(data.operation, data.iccid)
            lpa.notify()
            return result
        end
        if method == 'POST' and path == '/api/forward-test' then
            return require('forward').test()
        end
        if method == 'POST' and path == '/api/modem-reboot' then
            return {ready=require('modem').restart()}
        end
        if method == 'POST' and path == '/api/provision-mode' then
            assert(lpa.job.state~='running' and lpa.notification_job.state~='running', '卡片任务正在运行')
            return require('provision').request()
        end
        if method == 'POST' and path == '/api/reboot' then
            sys.timerStart(rtos.reboot, 1000); return {rebooting=true}
        end
        error('Unknown endpoint', 0)
    end)
    response(ctrl, ok and '200 OK' or '400 Bad Request', json.encode(ok and value or {error=tostring(value)}))
end

function M.start(provisioning)
    setup_mode=provisioning==true
    if not setup_mode then
        link=require('device_status'); euicc=require('euicc'); sms=require('sms'); lpa=require('lpa')
    end
    local adapter=setup_mode and socket.LWIP_AP or socket.LWIP_STA
    sys.taskInit(function()
        while not socket.adapter(adapter) do sys.wait(1000) end
        local server = assert(socket.create(adapter, callback), 'Cannot create HTTP socket')
        events = {}
        assert(socket.config(server, 80), 'Cannot set HTTP port')
        local ok, up = socket.linkup(server)
        assert(ok, 'Network unavailable')
        if not up then wait(server, socket.LINK, 10000) end
        log.info('web', 'Listening', wlan.getIP(), 80)
        while true do
            events = {}
            local listen_ok, connected = socket.listen(server)
            assert(listen_ok, 'Listen failed')
            if not connected then wait(server, socket.ON_LINE, 0) end
            local accepted, child = socket.accept(server, callback)
            if accepted then
                local client = child or server
                local success, err = pcall(serve, client)
                if not success then log.warn('web', tostring(err)) end
                local closing, closed = socket.discon(client)
                if closing and not closed then pcall(wait, client, socket.CLOSED, 5000) end
                socket.close(client)
                if child then socket.release(child); events = {} end
                collectgarbage('collect')
            end
        end
    end)
end
return M
