-- Small outbound HTTP client; the PC provides the local command queue.
local sys = require('sys')
local config = require('config')
local modem = require('modem')
local euicc = require('euicc')
local sms = require('sms')
local M = {}
local last_id, last_result, lpa_channel
local uptime = 0
sys.timerLoopStart(function() uptime = uptime + 1 end, 1000)

function M.status()
    collectgarbage('collect')
    local lt, lu, lm = rtos.meminfo('lua')
    local st, su, sm = rtos.meminfo('sys')
    return {version = VERSION, ready = modem.ready, ip = wlan.getIP(), uptime_seconds = uptime, utc = os.time(),
        lua = {total = lt, used = lu, maximum = lm, free = lt - lu},
        system = {total = st, used = su, maximum = sm, free = st - su},
        received = sms.received, pending_sms = #sms.pending,
        apdu_transport = true, standalone_download = true, download_verified = true, modem=modem.radio, modem_updating=modem.radio_refreshing,
        download = require('lpa').job, notifications = require('lpa').notification_job, forwarding = require('forward').last}
end

local function execute(job)
    if job.op == 'status' then return M.status() end
    if job.op == 'inbox' then return {messages = sms.recent} end
    assert(modem.ready, 'AIR is still initializing')
    if job.op == 'info' then return euicc.info() end
    if job.op == 'list' then return euicc.list() end
    if job.op == 'enable' or job.op == 'disable' or job.op == 'delete' then
        assert(not lpa_channel, 'Close LPA session first')
        return euicc.change(job.op, job.iccid)
    end
    if job.op == 'lpa_open' then
        assert(not lpa_channel, 'LPA session already open')
        lpa_channel = euicc.open(job.aid)
        return {channel = lpa_channel}
    end
    if job.op == 'lpa_apdu' then
        assert(lpa_channel, 'No LPA session')
        return {apdu = euicc.transmit(lpa_channel, job.apdu)}
    end
    if job.op == 'lpa_close' then
        if lpa_channel then euicc.close(lpa_channel); lpa_channel = nil end
        return {closed = true}
    end
    if job.op == 'restart' then return {ready = modem.restart()} end
    error('Unknown operation: ' .. tostring(job.op), 0)
end

function M.start()
    sys.taskInit(function()
        while not wlan.getIP() or wlan.getIP() == '0.0.0.0' do sys.wait(1000) end
        local report_at = 0
        while true do
            local packet = {result = last_result, sms = sms.pending[1]}
            if uptime >= report_at then
                packet.status = M.status(); report_at = uptime + 10
            end
            local code, _, body = http.request('POST', config.debug_url,
                {['Content-Type']='application/json', ['Authorization']='Bearer ' .. config.debug_token},
                json.encode(packet), {timeout=5000}).wait()
            if code == 200 then
                local reply = json.decode(body)
                if reply.ack_sms and sms.pending[1] and reply.ack_sms == sms.pending[1].id then
                    table.remove(sms.pending, 1)
                end
                if type(reply.command) == 'table' then
                    local job = reply.command
                    if job.id ~= last_id then
                        local ok, result = pcall(execute, job)
                        last_id = job.id
                        last_result = {id=job.id, ok=ok, data=ok and result or nil,
                            error=not ok and tostring(result) or nil}
                        collectgarbage('collect')
                    end
                elseif reply.ack_result == last_id then last_result = nil end
            end
            sys.wait(config.poll_ms)
        end
    end)
end
return M
