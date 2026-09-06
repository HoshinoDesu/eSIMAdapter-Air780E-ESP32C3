local config = require('config')
local M = {}
local fields = {'forward_url','forward_token','serverchan3_enabled','serverchan3_key','device_name'}
config.serverchan3_enabled = false
config.serverchan3_key = ''
config.device_name = 'Air780E'
function M.load()
    local f = io.open('/settings.json', 'r')
    if not f then return end
    local data = json.decode(f:read('*a')); f:close()
    if data.wifi then config.wifi = data.wifi end
    for _, name in ipairs(fields) do if data[name] ~= nil then config[name] = data[name] end end
end
function M.public()
    return {ssid=config.wifi.ssid, forward_url=config.forward_url,
        has_wifi_password=config.wifi.password ~= '', has_forward_token=config.forward_token ~= '',
        serverchan3_enabled=config.serverchan3_enabled, device_name=config.device_name,
        has_serverchan3_key=config.serverchan3_key ~= ''}
end
function M.save(data)
    local next_config = {wifi={ssid=data.ssid or config.wifi.ssid,
        password=(data.password and data.password ~= '') and data.password or config.wifi.password}}
    for _, name in ipairs(fields) do
        next_config[name] = data[name]
        if data[name] == nil or ((name == 'forward_token' or name == 'serverchan3_key') and data[name] == '') then
            next_config[name] = config[name]
        end
    end
    assert(next_config.forward_url == '' or next_config.forward_url:match('^https?://'), '转发地址需要 http:// 或 https://')
    if next_config.serverchan3_enabled then
        assert(next_config.serverchan3_key:match('^sctp%d+t[%w%-_]+$'), '请输入 Server酱³ 的 sctp 开头 SendKey')
    end
    local f = assert(io.open('/settings.json', 'w'), 'Cannot save settings')
    assert(f:write(json.encode(next_config))); f:close()
    local changed = next_config.wifi.ssid ~= config.wifi.ssid or next_config.wifi.password ~= config.wifi.password
    config.wifi = next_config.wifi
    for _, name in ipairs(fields) do config[name] = next_config[name] end
    return {saved=true, restart_required=changed}
end
return M
