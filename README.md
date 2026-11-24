# VideoCut++

Apple Silicon macOS 桌面视频剪辑工具。打开 `dist/VideoCut++.app`，可粘贴 B 站、YouTube 或抖音链接，也可打开本地视频。

1. 打开右上角设置，选择 OpenAI GPT 或智谱 GLM，填写并保存 API Key，再点「测试连接」。设置页会显示本机依赖状态。
2. 粘贴链接，点「下载并准备剪辑」。导入本地视频时，点「AI 分析」和「检测并修补」。
3. 点击切点跳转预览。可手动增加、调整或移除切点。用「查看原片」对照修补结果。遇到待复核区间，跳转后框选原片中的水印，再重新处理。
4. 点「导出 MP4」选择文件夹。每次导出创建独立目录，片段按编号排列。

每段目标约 60 秒，实际时长由内容边界决定。原始下载文件在 `~/Library/Application Support/VideoCut++/Jobs`。分析会向你选择的服务发送缩略图、时间点及本地转写，水印修补和剪辑在本机执行。压住主体或大面积移动的水印可能留下修补痕迹。

抖音有时会要求较新的 Cookie。遇到此提示时，可在设置中选取你自己的 Netscape 格式 Cookie 文件。应用仅临时复制抖音域名的记录供下载使用。也可直接导入已有视频。

## 本地构建和检查

```sh
bash Tools/setup.sh
bash Tools/build-app.sh
bash Tools/check.sh
VIDEOCUT_TEST_MEDIA=/absolute/path/to/video.mp4 bash Tools/check.sh
"$HOME/Library/Application Support/VideoCut++/venv/bin/python" Tools/check-watermark.py
```
