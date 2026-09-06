-- Air780E V1183 network-service AT queries; values follow the vendor manual.
local modem=require('modem')
local M={}
local function reply(command,pattern)
    for _,line in ipairs(modem.command(command,3000)) do
        local value=line:match(pattern)
        if value then return value end
    end
end
function M.read()
    return modem.exclusive(function()
        local s={sim_status=reply('AT+CPIN?','^%+CPIN:%s*(.+)')}
        s.registration=tonumber(reply('AT+CEREG?','^%+CEREG:%s*%d+,%s*(%d+)'))
        local r=s.registration
        s.registered=r==1 or r==5 or r==6 or r==7 or r==9 or r==10
        if s.registered then s.roaming=r==5 or r==7 or r==10 end
        local cops=reply('AT+COPS?','^%+COPS:%s*(.+)')
        if cops then
            s.operator=cops:match('"(.-)"')
            s.access_technology=tonumber(cops:match('"%s*,%s*(%d+)'))
        end
        s.csq=tonumber(reply('AT+CSQ','^%+CSQ:%s*(%d+)'))
        local cesq=reply('AT+CESQ','^%+CESQ:%s*(.+)')
        if cesq then
            local q,p=cesq:match('^%d+,%s*%d+,%s*%d+,%s*%d+,%s*(%d+),%s*(%d+)')
            s.rsrq=tonumber(q); s.rsrp=tonumber(p)
        end
        s.iccid=reply('AT+CCID','^(%d+F?)$')
        if s.iccid then s.iccid=s.iccid:gsub('F$','') end
        s.imei=reply('AT+CGSN','^(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d)$')
        s.attached=reply('AT+CGATT?','^%+CGATT:%s*(%d+)')=='1'
        s.updated_at=os.time()
        return s
    end)
end
return M
