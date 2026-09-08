local sys = require('sys')
local modem = require('modem')
local sms = require('sms')
local M = {}
local uptime = 0
sys.timerLoopStart(function() uptime = uptime + 1 end, 1000)

function M.status()
    collectgarbage('collect')
    local lt, lu, lm = rtos.meminfo('lua')
    local st, su, sm = rtos.meminfo('sys')
    return {version = VERSION, ready = modem.ready, ip = wlan.getIP(), uptime_seconds = uptime, utc = os.time(),
        lua = {total = lt, used = lu, maximum = lm, free = lt - lu},
        system = {total = st, used = su, maximum = sm, free = st - su},
        websocket = M.websocket,
        received = sms.received, pending_sms = #sms.pending,
        apdu_transport = true, standalone_download = true, download_verified = true, modem=modem.radio, modem_updating=modem.radio_refreshing,
        download = require('lpa').job, notifications = require('lpa').notification_job, forwarding = require('forward').last}
end

return M
