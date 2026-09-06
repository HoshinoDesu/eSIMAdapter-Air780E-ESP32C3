-- Serialize outbound requests so two TLS handshakes do not compete for RAM.
local sys = require('sys')
local M = {}
local busy = false
function M.request(method, url, headers, body, options)
    while busy do sys.waitUntil('OUTBOUND_FREE') end
    busy = true
    collectgarbage('collect')
    local ok, code, response_headers, result, detail = pcall(function()
        return http.request(method, url, headers, body, options).wait()
    end)
    busy = false
    sys.publish('OUTBOUND_FREE')
    if not ok then error(code, 0) end
    return code, response_headers, result, detail
end
return M
