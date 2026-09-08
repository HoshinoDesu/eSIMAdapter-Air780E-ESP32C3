-- Sequential JSON/base64/DER reader: no complete profile package in Lua RAM.
local euicc = require('euicc')
local M = {}
local function chars(f)
    local buffer, pos, offset = '', 1, f:seek()
    local function get()
        if pos > #buffer then buffer=f:read(1024) or ''; pos=1 end
        if #buffer == 0 then return end
        local c=buffer:sub(pos,pos); pos=pos+1; offset=offset+1
        return c, offset
    end
    local function run(n, finish)
        if pos > #buffer then buffer=f:read(1024) or ''; pos=1 end
        local size=math.min(n,#buffer-pos+1,finish-offset)
        if size<=0 then return nil end
        local value=buffer:sub(pos,pos+size-1)
        local special=value:find('[\\%s]')
        if special then value=value:sub(1,special-1) end
        pos=pos+#value; offset=offset+#value
        return value
    end
    return get,run
end
function M.scan(f)
    f:seek('set',0)
    local get=chars(f)
    local output, start, finish={}, nil, nil
    local c, offset=get()
    while c do
        if c == '"' then
            local raw='"'
            repeat
                c,offset=get(); assert(c,'Incomplete JSON string')
                raw=raw..c
                if c == '\\' then c,offset=get(); raw=raw..assert(c) elseif c == '"' then break end
            until false
            output[#output+1]=raw
            if raw == '"boundProfilePackage"' then
                repeat c,offset=get(); output[#output+1]=c until not c:match('%s')
                assert(c==':','Invalid package JSON')
                repeat c,offset=get() until not c:match('%s')
                assert(c=='"','Missing package string'); start=offset
                repeat
                    c,offset=get(); assert(c,'Incomplete package file')
                    if c=='\\' then c,offset=get() elseif c=='"' then finish=offset-1; break end
                until false
                output[#output+1]='""'
            end
        else output[#output+1]=c end
        c,offset=get()
    end
    local meta=json.decode(table.concat(output))
    return meta,start,finish
end
function M.install(f, start, finish, ch, progress)
    f:seek('set',start)
    local get,run=chars(f)
    local pending,consumed='',0
    local function read(n)
        while #pending<n do
            local encoded=''
            while #encoded<256 do
                local value=run(256-#encoded,finish)
                if value==nil then break end
                if value~='' then encoded=encoded..value
                else
                    local c=get()
                    if c=='\\' then
                        c=get()
                        if c=='u' then
                            local h=get()..get()..get()..get(); c=string.char(tonumber(h,16))
                        elseif c=='n' or c=='r' or c=='t' then c=' ' end
                    end
                    if not c:match('%s') then encoded=encoded..c end
                end
            end
            assert(#encoded>0 and #encoded%4==0,'Incomplete base64 package')
            pending=pending..crypto.base64_decode(encoded)
        end
        local value=pending:sub(1,n); pending=pending:sub(n+1); consumed=consumed+n
        return value
    end
    local function header()
        local h=read(1); local tag=h:byte()
        if tag&31==31 then
            repeat local b=read(1); h=h..b; tag=tag*256+b:byte() until b:byte()&128==0
        end
        local b=read(1); h=h..b; local length=b:byte()
        if length&128~=0 then
            local count=length&127; assert(count>0,'Indefinite DER length'); length=0
            for _=1,count do b=read(1); h=h..b; length=length*256+b:byte() end
        end
        return tag,length,h
    end
    local result
    local function send(h,n)
        local prefix=h
        local raw=euicc.exchange_stream(ch,#h+n,function(count)
            local out=prefix:sub(1,count); prefix=prefix:sub(#out+1)
            if #out<count then out=out..read(count-#out) end
            return out
        end)
        if #raw>0 then
            local data=euicc.field(euicc.field(raw,0xBF37),0xBF27)
            local tag,detail=euicc.tlvs(euicc.field(data,0xA2))()
            if tag==0xA1 then error('安装错误：步骤 '..euicc.hex(euicc.field(detail,0x80))..'，原因 '..euicc.hex(euicc.field(detail,0x81)),0) end
            assert(tag==0xA0,'Unknown installation result'); result=raw
        end
        progress(consumed)
    end
    local tag,total,outer=header(); assert(tag==0xBF36,'Missing BoundProfilePackage')
    local endpos=consumed+total
    local n,h
    tag,n,h=header(); assert(tag==0xBF23,'Missing secure channel'); send(outer..h,n)
    tag,n,h=header(); assert(tag==0xA0,'Missing first sequence'); send(h,n)
    local function sequence(wanted)
        assert(tag==wanted,'Unexpected package sequence')
        local last=consumed+n; send(h,0)
        while consumed<last do
            local child,length,head=header()
            assert(child==(wanted==0xA1 and 0x88 or 0x86),'Unexpected package element')
            send(head,length)
        end
        assert(consumed==last,'Invalid sequence length')
    end
    tag,n,h=header(); sequence(0xA1)
    tag,n,h=header()
    if tag==0xA2 then send(h,n); tag,n,h=header() end
    sequence(0xA3)
    assert(consumed==endpos and result,'Missing final installation result')
    return result
end
return M
