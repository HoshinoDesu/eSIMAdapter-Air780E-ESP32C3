local config = require('config')
local M = {}
local fields = {'access_key','forward_url','forward_token','serverchan3_enabled','serverchan3_key','device_name'}
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
local function persist(data)
    local f = assert(io.open('/settings.json', 'w'), '无法保存设置')
    local ok = f:write(json.encode(data)); f:close()
    assert(ok, '无法保存设置')
end
function M.provision(data)
    assert(type(data)=='table', '配置格式错误')
    local key = data.access_key
    assert(type(key)=='string' and #key>=1 and #key<=128 and not key:find('[%c]'), '请填写访问密钥（最多 128 字节）')
    assert(config.access_key=='' or key==config.access_key, '访问密钥错误')
    assert(type(data.ssid)=='string' and #data.ssid>=1 and #data.ssid<=32 and not data.ssid:find('%z'), 'Wi-Fi 名称应为 1～32 字节')
    assert(type(data.password)=='string' and (#data.password==0 or (#data.password>=8 and #data.password<=63)) and not data.password:find('%z'), 'Wi-Fi 密码应为 8～63 字节，无密码网络请留空')
    local next_config = {wifi={ssid=data.ssid,password=data.password}}
    for _,name in ipairs(fields) do next_config[name]=config[name] end
    next_config.access_key=key
    persist(next_config)
    config.wifi=next_config.wifi; config.access_key=key
    return {saved=true}
end
function M.save(data)
    local next_config = {wifi={ssid=data.ssid or config.wifi.ssid,
        password=(data.password and data.password ~= '') and data.password or config.wifi.password}}
    for _, name in ipairs(fields) do
        next_config[name] = name ~= 'access_key' and data[name] or config[name]
        if data[name] == nil or ((name == 'forward_token' or name == 'serverchan3_key') and data[name] == '') then
            next_config[name] = config[name]
        end
    end
    assert(next_config.forward_url == '' or next_config.forward_url:match('^https?://'), '转发地址需要 http:// 或 https://')
    if next_config.serverchan3_enabled then
        assert(next_config.serverchan3_key:match('^sctp%d+t[%w%-_]+$'), '请输入 Server酱³ 的 sctp 开头 SendKey')
    end
    persist(next_config)
    local changed = next_config.wifi.ssid ~= config.wifi.ssid or next_config.wifi.password ~= config.wifi.password
    config.wifi = next_config.wifi
    for _, name in ipairs(fields) do config[name] = next_config[name] end
    return {saved=true, restart_required=changed}
end
return M
