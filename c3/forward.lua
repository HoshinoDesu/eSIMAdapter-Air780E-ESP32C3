local config = require('config')
local outbound = require('outbound')
local M = {last={}}
local function post(url, headers, payload)
    local code, _, body = outbound.request('POST', url, headers, json.encode(payload), {timeout=30000})
    assert(code and code >= 200 and code < 300, 'HTTP ' .. tostring(code))
    return body
end
function M.send(message)
    local result = {}
    if config.forward_url ~= '' then
        local ok, err = pcall(post, config.forward_url,
            {['Content-Type']='application/json', ['Authorization']='Bearer ' .. config.forward_token}, message)
        result.http = {ok=ok, message=ok and '已发送' or tostring(err)}
        M.last.http = result.http
    end
    if config.serverchan3_enabled then
        local ok, err = pcall(function()
            local uid = assert(config.serverchan3_key:match('^sctp(%d+)t'), 'Invalid Serverchan3 key')
            local body = post('https://' .. uid .. '.push.ft07.com/send/' .. config.serverchan3_key .. '.send',
                {['Content-Type']='application/json;charset=utf-8'},
                {title=message.sender, desp=(message.text or '二进制短信') .. '\n\n**发送人:** ' .. message.sender ..
                    '  \n**时间:** ' .. (message.timestamp or ''):sub(1,19):gsub('T',' ') ..
                    '  \n**设备:** ' .. config.device_name, tags=config.device_name})
            local result = json.decode(body)
            assert(result.code == 0, result.message or result.msg or ('Serverchan3 code ' .. tostring(result.code)))
        end)
        result.serverchan3 = {ok=ok, message=ok and '已发送' or tostring(err)}
        M.last.serverchan3 = result.serverchan3
    end
    return result
end
function M.test()
    assert(config.forward_url ~= '' or config.serverchan3_enabled, '请先保存并启用推送通道')
    return M.send({id='test-' .. os.time(), sender='推送测试',
        timestamp=os.date('%Y-%m-%dT%H:%M:%S'), text='这是一条推送测试消息。'})
end
return M
