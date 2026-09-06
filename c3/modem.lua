-- AIR780E UART1: C3 GPIO0 TX -> MRX, GPIO1 RX <- MTX.
local sys = require("sys")
local M = {ready = false, radio = {}, radio_refreshing = false}
local owner, depth, pending
local rx, sms_length = "", nil
local sequence = 0

local function lock()
    local me = coroutine.running()
    while owner and owner ~= me do sys.waitUntil("AT_FREE", 1000) end
    owner, depth = me, (depth or 0) + 1
end

local function unlock()
    depth = depth - 1
    if depth == 0 then owner = nil; sys.publish("AT_FREE") end
end

function M.exclusive(fn)
    lock()
    local ok, value = pcall(fn)
    unlock()
    if not ok then error(value, 0) end
    return value
end

local function line_received(line)
    if line == "" then return end
    local length = line:match('^%+CMT:.*,(%d+)$')
    if length then sms_length = tonumber(length); return end
    if sms_length and line:match('^%x+$') then
        sys.publish("SMS_PDU", line, sms_length)
        sms_length = nil
        return
    end
    if not pending or line == pending.command then return end
    if line == "OK" or line == "ERROR" or line:match('^%+CM[ES] ERROR:') then
        pending.terminal = line
        sys.publish(pending.event)
    else
        pending.lines[#pending.lines + 1] = line
    end
end

function M.start()
    assert(uart.setup(1, 115200, 8, 1) == 0, "UART1 setup failed")
    uart.on(1, "receive", function(id)
        while true do
            local chunk = uart.read(id, 2048)
            if #chunk == 0 then break end
            rx = rx .. chunk
            while true do
                local pos = rx:find("\n", 1, true)
                if not pos then break end
                local line = rx:sub(1, pos - 1):gsub("\r$", "")
                rx = rx:sub(pos + 1)
                line_received(line)
            end
        end
    end)
end

function M.command(command, timeout)
    return M.exclusive(function()
        collectgarbage("collect")
        sequence = sequence + 1
        local req = {command = command, lines = {}, event = "AT_" .. sequence}
        pending = req
        uart.write(1, command .. "\r\n")
        sys.waitUntil(req.event, timeout or 5000)
        pending = nil
        if req.terminal ~= "OK" then
            -- On a timeout discard late response fragments before another command.
            if not req.terminal then sys.wait(300); rx = "" end
            error((req.terminal or "AT timeout") .. ": " .. command:match('^[^=]*'), 0)
        end
        return req.lines
    end)
end

function M.configure_sms()
    M.command("AT+CMGF=0")
    M.command('AT+CSCS="UCS2"')
    M.command("AT+CNMI=2,2,0,0,0")
end

function M.initialize()
    return M.exclusive(function()
        M.command("AT")
        local pin = table.concat(M.command("AT+CPIN?"), "\n")
        assert(pin:find("READY", 1, true), pin)
        M.configure_sms()
        M.command('AT+COPS=3,0')
        M.ready = true
        sys.publish("MODEM_READY")
        return true
    end)
end

function M.restart()
    return M.exclusive(function()
        M.ready = false
        M.radio = {}
        pcall(M.command, "AT+RESET", 3000)
        sys.wait(8000)
        for _ = 1, 20 do
            local ok = pcall(M.initialize)
            if ok then return true end
            sys.wait(1000)
        end
        error("AIR did not become ready after reset", 0)
    end)
end

return M
