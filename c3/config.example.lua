return {
    device_name = "Air780E", -- 短信推送中的设备名和标签
    access_key = "", -- 网页面板访问密钥，自行填写

    wifi = {
        ssid = "",
        password = "",
    },

    provisioning = {
        ap_password = "", -- 配网热点默认无密码；可选填 8～63 个字符
        timeout_seconds = 30, -- 开机连接 Wi-Fi 的等待秒数
    },

    forward_url = "", -- HTTP 短信转发地址，留空关闭
    forward_token = "", -- 接收接口的 Bearer Token，可留空

    serverchan3_enabled = false,
    serverchan3_key = "", -- Server酱³ SendKey
}
