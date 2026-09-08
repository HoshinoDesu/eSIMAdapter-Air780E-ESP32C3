# 编译与刷写

需要 Python 3.8+ 和 Luatools 中的 32 位 Lua 5.3 编译器 `luac_536.exe`。

在项目根目录执行：

```powershell
python -m venv .venv-esp
.\.venv-esp\Scripts\python.exe -m pip install -r requirements-dev.txt
Copy-Item c3/config.example.lua c3/config.lua
```

可在 `c3/config.lua` 中预填 Wi-Fi 和网页访问密钥 `access_key`，也可以留空、刷写后通过热点配网。然后编译。`LUAC` 改为自己的编译器路径：

```powershell
$env:LUAC = 'D:\Luatools\_temp\tools\luac_536.exe'
.\.venv-esp\Scripts\python.exe c3/build.py
```

`config.lua` 可设置设备名、Wi-Fi、网页访问密钥、HTTP 转发和 Server酱³。网页中保存的设置优先于文件中的初始值。`provisioning` 可设置热点密码和开机联网等待时间；初次配网设置访问密钥，重新配网使用原密钥。

生成文件为 `c3/build/script.bin`。首次刷写按 [固件包说明](../firmware/prebuilt/README.md) 操作，使用生成的脚本替换包内 `script.bin`。

只更新脚本时，断电拆开叠插、仅接 C3 USB，执行以下命令，端口改为实际值：

```powershell
.\.venv-esp\Scripts\python.exe -m esptool --chip esp32c3 --port COM22 --baud 460800 --before default_reset --after hard_reset write_flash 0x390000 c3/build/script.bin
```

刷完重新叠插，仅接 AIR780E USB，在浏览器打开 `http://设备地址/`。设备地址可从路由器查看。
