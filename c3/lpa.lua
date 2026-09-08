-- Fresh SGP.22 ES9+/ES10b implementation; protocol reference: lpac v2.3.0 / rsp.asn.
local sys=require('sys')
local euicc=require('euicc')
local modem=require('modem')
local outbound=require('outbound')
local M={notification_job={state='idle',sent=0,failed=0},job={state='idle',stage='尚未开始'}}
local wrap,field,unhex=euicc.wrap,euicc.field,euicc.unhex
local enc,dec=crypto.base64_encode,crypto.base64_decode
local function host(value)
    assert(type(value)=='string' and value:match('^[%w][%w%.%-]*[%w]$'), 'SM-DP+ 地址应为域名')
    return value
end
local function check(reply)
    local execution=reply.header.functionExecutionStatus
    local detail=execution.statusCodeData or {}
    assert(execution.status=='Executed-Success', 'SM-DP+ '..(detail.subjectCode or '')..'/'..(detail.reasonCode or '')..' '..(detail.message or execution.status))
    return reply
end
local log_revision,log_generation=0,0
local function trace(message)
    local f=io.open('/lpa-download.log','a')
    if not f then M.job.log_error='无法保存下卡日志'; return end
    local ok=f:write(os.date('[%H:%M:%S] ')..message..'\n'); f:close()
    if not ok then M.job.log_error='无法保存下卡日志'; return end
    log_revision=log_revision+1; M.job.log_revision=log_revision
end
local function request(address,operation,data,dst)
    local logging=M.job.state=='running'
    if logging then trace('→ '..operation) end
    local code,_,body,detail=outbound.request('POST','https://'..host(address)..'/gsma/rsp2/es9plus/'..operation,
        {['Content-Type']='application/json',['User-Agent']='gsma-rsp-lpad',['X-Admin-Protocol']='gsma/rsp/v2.2.0'},
        json.encode(data),{timeout=90000,dst=dst})
    if logging then trace('← '..operation..' HTTP '..tostring(code)) end
    assert(code and code>=200 and code<300,operation..' HTTP '..tostring(code)..(detail and (' TLS '..tostring(detail.tls_error)..' verify '..tostring(detail.verify_flags)) or ''))
    if operation=='handleNotification' or operation=='cancelSession' then return true end
    if not dst then return check(json.decode(body)) end
end
local function card(ch,tag,body)
    local raw=euicc.exchange(ch,wrap(tag,body))
    local kind,detail=euicc.tlvs(field(raw,tonumber(tag,16)))()
    if kind==0xA1 then error('eUICC '..tag..' error '..euicc.hex(detail),0) end
    assert(kind==0xA0,'Unexpected '..tag..' response')
    return raw
end
local function stage(value) M.job.stage=value; trace(value); collectgarbage('collect') end
local function run(address,matching,confirmation)
    return euicc.session(function(ch)
        local transaction,transaction_bytes,installed
        local ok,err=pcall(function()
            stage('读取卡片认证信息')
            local challenge=euicc.exchange(ch,unhex('BF2E00'))
            local info=euicc.exchange(ch,unhex('BF2000'))
            stage('连接 SM-DP+ 服务器')
            local reply=request(address,'initiateAuthentication',{smdpAddress=address,
                euiccChallenge=enc(field(field(challenge,0xBF2E),0x80)),euiccInfo1=enc(info)})
            challenge,info=nil,nil
            transaction=reply.transactionId
            local signed=dec(reply.serverSigned1)
            transaction_bytes=field(field(signed,0x30),0x80)
            assert(euicc.hex(transaction_bytes)==transaction:upper(),'Transaction ID mismatch')
            local imei
            for _,line in ipairs(modem.command('AT+CGSN',5000)) do if line:match('^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$') then imei=line end end
            assert(imei,'AIR did not return its IMEI')
            local bcd=unhex((imei..'F'):gsub('(.)(.)','%2%1'))
            local context=wrap('A0',wrap('80',matching)..wrap('A1',wrap('80',bcd:sub(1,4))..wrap('A1','')..wrap('82',bcd)))
            local payload=signed..dec(reply.serverSignature1)..dec(reply.euiccCiPKIdToBeUsed)..dec(reply.serverCertificate)..context
            reply,signed,context=nil,nil,nil
            trace('initiateAuthentication 完成')
            stage('卡片验证服务器 · BF38')
            local authentication=card(ch,'BF38',payload); payload=nil
            trace('BF38 卡片验证通过')
            stage('服务器验证卡片')
            reply=request(address,'authenticateClient',{transactionId=transaction,authenticateServerResponse=enc(authentication)})
            authentication=nil
            local signed2=dec(reply.smdpSigned2)
            local signed_data=field(signed2,0x30)
            assert(field(signed_data,0x80)==transaction_bytes,'Download transaction mismatch')
            local cc=''
            if field(signed_data,0x01):byte()~=0 then
                assert(confirmation~='','此激活码需要确认码，请填写后重新开始')
                cc=wrap('04',unhex(crypto.sha256(unhex(crypto.sha256(confirmation))..transaction_bytes)))
            end
            trace('authenticateClient 完成')
            stage('准备下卡 · BF21')
            payload=signed2..dec(reply.smdpSignature2)..cc..dec(reply.smdpCertificate)
            reply,signed2,signed_data,cc=nil,nil,nil,nil
            local prepared=card(ch,'BF21',payload); payload=nil
            trace('BF21 准备完成')
            stage('下载配置包到设备存储')
            request(address,'getBoundProfilePackage',{transactionId=transaction,prepareDownloadResponse=enc(prepared)},'/lpa-package.json')
            prepared=nil
            local f=assert(io.open('/lpa-package.json','rb'),'配置包文件不存在')
            trace('配置包文件 '..f:seek('end')..' 字节')
            local loaded,result=pcall(function()
                local bpp=require('bpp')
                local metadata,start,finish=bpp.scan(f); check(metadata)
                assert(start and finish,'服务器未返回配置包')
                stage('正在写入 eUICC · BF36')
                local last=0
                return bpp.install(f,start,finish,ch,function(n)
                    M.job.written_bytes=n
                    if n-last>=4096 then trace('已写入 '..n..' 字节'); last=n end
                end)
            end)
            f:close(); os.remove('/lpa-package.json')
            if not loaded then error(result,0) end
            installed=true; M.job.installed=true
            trace('BF37 安装成功，共写入 '..M.job.written_bytes..' 字节')

        end)
        if not ok then trace('错误：'..tostring(err)) end
        if not ok and transaction_bytes and not installed then
            trace('取消未完成的下载会话 · BF41')
            local cancelled,cancel_error=pcall(function()
                local raw=euicc.exchange(ch,wrap('BF41',wrap('80',transaction_bytes)..wrap('81',string.char(127))))
                request(address,'cancelSession',{transactionId=transaction,cancelSessionResponse=enc(raw)})
            end)
            if not cancelled then M.job.warning='会话取消未完成：'..tostring(cancel_error); trace(M.job.warning)
            else trace('下载会话已取消') end
        end
        os.remove('/lpa-package.json')
        if not ok then error(err,0) end
        return {installed=installed}
    end)
end
function M.probe(address)
    local code,_,_,detail=outbound.request('GET','https://'..host(address)..'/',{},nil,{timeout=20000})
    return {http_code=code,tls=detail,utc=os.time()}
end
function M.start(data)
    assert(M.job.state~='running','下卡任务正在运行')
    assert(M.notification_job.state~='running','LPA notifications are running')
    assert(modem.ready,'AIR 尚未就绪')
    local code=assert(data.activation_code,'请输入激活码'):gsub('^LPA:','')
    local parts={}
    for part in (code..'$'):gmatch('(.-)%$') do parts[#parts+1]=part end
    assert(parts[1]=='1' and parts[2] and parts[3] and parts[3]~='','激活码格式应为 LPA:1$域名$令牌')
    assert(#parts<=5 and (not parts[4] or parts[4]==''),'本版尚不支持带 SM-DP+ OID 的激活码')
    local address=host(parts[2]); local matching=parts[3]; local confirmation=data.confirmation_code or ''
    log_generation=log_generation+1
    M.job={state='running',stage='准备开始',written_bytes=0,log_generation=log_generation}
    os.remove('/lpa-download.log')
    trace('开始下卡 · SM-DP+ '..address)
    sys.taskInit(function()
        sys.wait(200)
        local ok,err=pcall(run,address,matching,confirmation)
        matching,confirmation=nil,nil
        unload('bpp')
        M.job.state=ok and 'done' or 'error'
        stage(ok and '配置已安装，可在列表中启用' or ('下卡失败：'..tostring(err)))
        collectgarbage('collect')
        M.notify(nil,true)
    end)
    return {started=true}
end
function M.notify(selected,download_log)
    assert(M.job.state~='running' and M.notification_job.state~='running','卡片任务正在运行')
    assert(modem.ready,'AIR 尚未就绪')
    if download_log then trace('读取并发送 LPA 通知') end
    M.notification_job={state='running',stage='读取待发通知',sent=0,failed=0,errors={}}
    sys.taskInit(function()
        sys.wait(200)
        local job=M.notification_job
        local ok,err=pcall(function() return require('notifications').flush(selected,job) end)
        unload('notifications')
        job.state=ok and (job.failed==0 and 'done' or 'error') or 'error'
        job.stage=ok and ('已发送 '..job.sent..' 条，待重发 '..job.failed..' 条') or tostring(err)
        if download_log then
            trace('通知结果：'..job.stage)
            for _,item in ipairs(job.errors) do trace('通知 #'..item.sequence..'：'..item.error) end
        end
        collectgarbage('collect')
    end)
    return {started=true}
end

M.request=request
return M
