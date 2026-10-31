# nPlayer 外部解码器构建（FFmpeg 4.4.x arm64）

## 背景

nPlayer（此 APK 内置 FFmpeg 4.2.1，Lavf58）的播放核心
`libnplayer.media.core.so` 通过 107 个 av* API 动态调用 FFmpeg，
且 App 自带外部解码器机制（设置里的 DecoderSettingView，
选中 .so 后拷贝为 `libffmpeg_tmp.so` 加载，失败回退内置）。

FFmpeg 保证同一主版本（Lavf58 = 4.x 全系列）ABI 兼容，
所以用 **4.4.x** 重编的 `libffmpeg.so` 可被核心直接加载，
且比内置 4.2.1 多了 AV1（dav1d）、大量解码修复。
5.x/6.x/7.x 会因结构体布局变化和 `av_init_packet` 删除而崩溃，不要用。

## 使用方法

1. 把本目录全部文件推到一个 **公开的 GitHub 仓库**（结构如下）：

   ```
   .github/workflows/build-ffmpeg.yml
   build.sh
   README.md
   ```

2. 仓库页 → Actions → **Build FFmpeg for nPlayer** → Run workflow
   （默认 FFmpeg 4.4.4 + dav1d，直接开跑）
3. 跑完在运行记录底部 **Artifacts** 下载 `libffmpeg-arm64`，
   解压得到 `libffmpeg.so`
4. 把 `libffmpeg.so` 传到手机（如 Download 目录）
5. nPlayer → 设置 → 解码器（Decoder）→ 选择这个 so 导入
6. 播放之前放不了的文件验证

## 工作流会自动验证

每次构建结束会检查 nplayer 核心引用的关键符号
（av_init_packet、avformat_open_input、sws_scale 等）是否都存在，
日志里出现全部 `OK` 才说明这个 so 能被加载。

## 回退

导入外部解码器后如果播放异常，去解码器设置里取消选择
（或清除应用数据），即回退到内置 4.2.1，无任何损失。

## 边界说明

- 仅限自用测试。nPlayer 是商业闭源 App（含 nPlayerSDK.lic），
  修改后的 APK / so 不要对外分发。
- 如果首次运行工作流报错，把失败日志贴出来即可定位。
