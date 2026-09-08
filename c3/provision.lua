local sys = require('sys')
local config = require('config')
local M = {}
local flag = '/wifi-setup.flag'
function M.request()
    local f = assert(io.open(flag, 'w'), '无法进入配网模式')
    assert(f:write('1')); f:close()
    sys.timerStart(rtos.reboot, 1000)
    return {rebooting=true, ssid='Air780E-' .. wlan.getMac():sub(-6), address='192.168.4.1'}
end
function M.boot()
    local forced = io.open(flag, 'r')
    if forced then forced:close(); os.remove(flag) end
    local options=config.provisioning or {}
    local timeout=options.timeout_seconds or 30
    local password=options.ap_password or ''
    assert(type(password)=='string' and (#password==0 or (#password>=8 and #password<=63)), '配网热点密码留空或填写 8～63 字节')
    assert(type(timeout)=='number' and timeout>=1 and timeout<=300, '配网等待时间应为 1～300 秒')
    wlan.init()
    if not forced and config.wifi.ssid ~= '' and config.access_key ~= '' then
        wlan.setMode(wlan.STATION)
        wlan.connect(config.wifi.ssid, config.wifi.password)
        for _ = 1, timeout do
            local ip = wlan.getIP()
            if ip and ip ~= '' and ip ~= '0.0.0.0' then return true end
            sys.wait(1000)
        end
    end
    wlan.disconnect()
    local ssid = 'Air780E-' .. wlan.getMac():sub(-6)
    assert(wlan.createAP(ssid, password, '192.168.4.1', '255.255.255.0', 6, {max_conn=2}), '无法启动配网热点')
    wlan.setMode(wlan.AP)
    require('web').start(true)
    return false
end
return M
