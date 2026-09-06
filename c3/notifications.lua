-- SGP.22 ES10b pending notifications; DER layout checked against lpac/rsp.asn.
local euicc=require('euicc')
local M={}
local field,wrap=euicc.field,euicc.wrap
local operations={[128]='install',[64]='enable',[32]='disable',[16]='delete'}
local function metadata(value)
    local item={}
    for tag,v in euicc.tlvs(value) do
        if tag==0x80 then
            item.id=euicc.hex(v); item.sequence=0
            for i=1,#v do item.sequence=item.sequence*256+v:byte(i) end
        elseif tag==0x81 then item.operation=operations[v:byte(2)] or 'unknown'
        elseif tag==0x0C then item.address=v
        elseif tag==0x5A then item.iccid=euicc.hex(v):gsub('(.)(.)','%2%1'):gsub('F+$','') end
    end
    return item
end
local function list(ch)
    local raw=euicc.exchange(ch,euicc.unhex('BF2800'))
    local items={}
    for tag,value in euicc.tlvs(field(field(raw,0xBF28),0xA0)) do
        if tag==0xBF2F then items[#items+1]=metadata(value) end
    end
    return items
end
function M.list()
    return euicc.session(function(ch) return {notifications=list(ch)} end)
end
local function send(ch,item)
    local seq=euicc.unhex(item.id)
    local raw=euicc.exchange(ch,wrap('BF2B',wrap('A0',wrap('80',seq))))
    local tag,value=euicc.tlvs(field(field(raw,0xBF2B),0xA0))()
    assert(tag==0xBF37 or tag==0x30,'卡片未返回待发通知')
    local meta=metadata(field(tag==0xBF37 and field(value,0xBF27) or value,0xBF2F))
    assert(meta.id==item.id,'通知序号不匹配')
    local pending=wrap(string.format('%X',tag),value)
    raw,value=nil,nil
    require('lpa').request(meta.address,'handleNotification',{pendingNotification=crypto.base64_encode(pending)})
    pending=nil
    local removed=euicc.exchange(ch,wrap('BF30',wrap('80',seq)))
    local code=field(field(removed,0xBF30),0x80):byte()
    assert(code==0 or code==1,'卡片确认通知失败：'..code)
end
function M.flush(selected,job)
    return euicc.session(function(ch)
        local items=list(ch)
        local found=not selected
        for _,item in ipairs(items) do
            if not selected or item.id==selected then
                found=true; job.stage='正在发送通知 '..item.sequence
                local ok,err=pcall(send,ch,item)
                if ok then job.sent=job.sent+1
                else
                    job.failed=job.failed+1
                    job.errors[#job.errors+1]={sequence=item.sequence,error=tostring(err)}
                end
                collectgarbage('collect')
            end
        end
        assert(found,'待发通知不存在')
        return {sent=job.sent,failed=job.failed}
    end)
end
return M
