# 精简 LuatOS 底层

底层基于 ESP-IDF v5.1.1、LuatOS 和 luatos-soc-idf5。版本见 [versions.json](versions.json)。

## 获取源码

以下命令在项目根目录执行：

```sh
git clone https://github.com/espressif/esp-idf.git firmware-build/esp-idf
git -C firmware-build/esp-idf checkout e088c3766ba440e72268b458a68f27b6e7d63986
git -C firmware-build/esp-idf submodule update --init --recursive

git clone https://github.com/openLuat/LuatOS.git firmware-build/LuatOS
git -C firmware-build/LuatOS checkout da2373564e282b420ffcdb6080323bffbd36f947
git -C firmware-build/LuatOS submodule update --init --recursive

git clone https://github.com/openLuat/luatos-soc-idf5.git firmware-build/luatos-soc-idf5
git -C firmware-build/luatos-soc-idf5 checkout bc90eaa2921bdb63bc0b1dc238df75fa83b04f90
git -C firmware-build/luatos-soc-idf5 submodule update --init --recursive
```

在项目根目录为上述源码应用补丁：

```powershell
$patchRoot = (Resolve-Path firmware/patches).Path
git -C firmware-build/luatos-soc-idf5 apply "$patchRoot/soc-minimal.patch"
git -C firmware-build/LuatOS apply "$patchRoot/luatos-tls-bundle.patch"
git -C firmware-build/LuatOS apply "$patchRoot/lwip-single-client.patch"
git -C firmware-build/esp-idf/components/mbedtls/mbedtls apply "$patchRoot/mbedtls-gsma-ci1-policy.patch"
Copy-Item firmware/gsma-ci1.pem firmware-build/luatos-soc-idf5/luatos/include/gsma-ci1.pem
```

按照 ESP-IDF v5.1.1 的工具安装与环境导出流程准备 ESP32-C3 工具链，在该环境中构建：

```sh
cd firmware-build/luatos-soc-idf5/luatos
idf.py set-target esp32c3
idf.py build
```

输出为 `build/bootloader/bootloader.bin`、`build/partition_table/partition-table.bin` 和 `build/luatos.bin`。Lua 脚本另用 [c3/build.py](../c3/build.py) 编译。

## 补丁与分区

- `soc-minimal.patch`：精简组件、136 KiB Lua 堆、USB 控制台、TLS 信任库及 ESP32-C3 构建配置。
- `luatos-tls-bundle.patch`：接入 ESP 证书库并回传 TLS 错误。
- `lwip-single-client.patch`：活动连接存在时拒绝第二个连接，避免 HTTP 响应错发。
- `mbedtls-gsma-ci1-policy.patch`：仅对指定 GSMA 根证书兼容 critical policy。

`gsma-ci1.pem` 为 GSMA 根证书，供出站 HTTPS 使用。

| 分区 | 起始偏移 | 大小 |
| --- | --- | --- |
| NVS | 0x9000 | 28 KiB |
| app0 | 0x10000 | 3584 KiB |
| script | 0x390000 | 128 KiB |
| SPIFFS | 0x3B0000 | 256 KiB |
| FDB | 0x3F0000 | 64 KiB |
