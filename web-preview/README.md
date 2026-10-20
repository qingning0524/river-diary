# 原有日记网页预览

此目录保存项目原有日记网页；对外官网、登录和用户中心在 `website/`。

| 路径 | 用途 |
|---|---|
| `index.html` | 网页模板 |
| `src/css/` | 按文件名顺序拼接的样式源文件 |
| `src/js/` | 按文件名顺序拼接的 JavaScript 源文件 |
| `css/style.css` | 管道生成的样式；修改 `src/css/` 后重新生成 |
| `js/app.js` | 管道生成的脚本；修改 `src/js/` 后重新生成 |

网页通过 `../data/data.json` 读取本机项目快照。完整数据构建继续用项目根 `build.py`，网页单文件输出继续放在 `dist/index.html`。

仅生成网页资源、不修改日记数据：

```bash
python3 -c 'from pipeline.assets import build_assets; build_assets()'
```

在项目根启动预览：

```bash
python3 -m http.server 8000 --bind 127.0.0.1
```

打开 `http://localhost:8000/web-preview/`。`make web` 会先运行完整数据构建及测试，包含数据快照与可能的 iCloud 同步。
