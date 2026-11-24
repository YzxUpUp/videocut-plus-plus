# VideoCut++

适用于 Apple Silicon Mac 的视频剪辑工具，要求 macOS 14 或更新版本。下载并解压后打开 `VideoCut++.app`，可粘贴 B 站、YouTube 或抖音链接，也可打开本地视频。[下载最新版](https://github.com/YzxUpUp/videocut-plus-plus/releases/latest)

1. 打开右上角设置，选择 OpenAI GPT 或智谱 GLM，填写并保存 API Key，再点「测试连接」。设置页会显示本机依赖状态。
2. 粘贴链接，点「下载并准备剪辑」。导入本地视频时，点「AI 分析」和「检测并修补」。
3. 点击切点，进度条和预览画面会跳到对应时间并暂停。可手动增加、调整或移除切点。用「查看原片」对照修补结果。遇到待复核区间，跳转后框选原片中的水印，再重新处理。
4. 点「导出 MP4」。设置了导出目录时直接导出，否则会询问文件夹。每次导出创建独立目录，片段按编号排列。

每段目标约 60 秒，实际时长由内容边界决定。原片默认保存在 `~/Library/Application Support/VideoCut++/Jobs` 下的任务子目录。可在「设置 → 存储位置」更改下载和 MP4 导出目录，当前文件保留在原位置。分析会向你选择的服务发送缩略图、时间点及本地转写，水印修补和剪辑在本机执行。压住主体或大面积移动的水印可能留下修补痕迹。

抖音有时会要求较新的 Cookie。遇到此提示时，可在设置中选取你自己的 Netscape 格式 Cookie 文件。应用仅临时复制抖音域名的记录供下载使用。也可直接导入已有视频。

「设置 → 存储位置 → 清理下载内容」会永久删除应用记录的下载原片和相关处理文件，并保留已导出的 MP4。清理前会提示确认，清理后无法复原。

## 本地构建和检查

```sh
bash Tools/setup.sh
bash Tools/build-app.sh
bash Tools/check.sh
VIDEOCUT_TEST_MEDIA=/absolute/path/to/video.mp4 bash Tools/check.sh
"$HOME/Library/Application Support/VideoCut++/venv/bin/python" Tools/check-watermark.py
```
