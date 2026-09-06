PROJECT = 'c3_euicc_sms'
VERSION = '0.3.11'
-- Standalone power has no USB console reader.
log.setLevel('SILENT')
-- Begin collection before the live Lua heap doubles beyond 96 KiB.
collectgarbage('setpause', 110)
collectgarbage('setstepmul', 200)
local sys = require('sys')
require('sysplus')
local config = require('config')
require('settings').load()
local modem = require('modem')
local sms = require('sms')
local link = require('debug_link')
local led = gpio.setup(12, 0)
local lit = false

modem.start()
wlan.init()
wlan.setMode(wlan.STATION)
wlan.connect(config.wifi.ssid, config.wifi.password)
sys.subscribe('IP_READY', function() log.info('wifi', 'Connected', wlan.getIP()) end)
sys.timerLoopStart(function()
    if modem.ready then led(1) else lit = not lit; led(lit and 1 or 0) end
end, 500)
sys.taskInit(function()
    while not modem.ready do
        local ok, err = pcall(modem.initialize)
        if not ok then log.info('air', tostring(err)); sys.wait(2000) end
    end
    log.info('air', 'SMS and eUICC UART ready')
end)
sys.subscribe('SMS_PDU', function(pdu)
    local ok, message = pcall(sms.accept, pdu)
    if not ok then log.error('sms', tostring(message)); return end
    if message then
        log.info('sms', 'Received', message.id)
        sys.taskInit(function() require('forward').send(message) end)
    end
end)
if config.debug_enabled then link.start() end
require("web").start()
sys.taskInit(function()
    while not modem.ready do sys.waitUntil('MODEM_READY') end
    while true do
        local lpa=require('lpa')
        if modem.ready and lpa.job.state~='running' and lpa.notification_job.state~='running' then
            modem.radio_refreshing=true
            local ok,value=pcall(function() return require('radio').read() end)
            unload('radio')
            modem.radio=ok and value or {error=tostring(value),updated_at=os.time()}
            modem.radio_refreshing=false
        end
        sys.waitUntil('RADIO_REFRESH',15000)
    end
end)
log.info('app', VERSION, 'Fresh SMS + ES10c implementation')
sys.run()
