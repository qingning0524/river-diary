# 官网赞助页部署（2026-10-21）

## 结果

- `https://flowriver.xyz/sponsor.html` 已上线，HTTP `200`。
- 首页导航与页脚新增「赞助」入口。
- 首页 iOS 下载卡改为「自有设备验证中 / 暂不提供 TestFlight」，与 D0 实际状态一致。
- 未修改 Caddy、未改动 `/var/www/flowriver/{login,user}`、未上传 DMG。

## 部署范围

从 `website/site/` 同步，排除 `downloads/` 与 `tests/`：

- `index.html`
- `sponsor.html`
- `privacy.html`
- `terms.html`
- `assets/site.js`

## 回滚点

- 服务器备份：`/var/backups/flowriver/site-before-sponsor-20261021T155043Z`
- 回滚命令示例：
  `rsync -a --delete /var/backups/flowriver/site-before-sponsor-20261021T155043Z/ /var/www/flowriver/site/`
  注意保留 `downloads/`（若线上存在）。

## 校验

| 文件 | SHA-256（本地与线上一致） |
| --- | --- |
| `index.html` | `132f75e38ffcecf61e92961588d6eabc14c0ea1d21c4c1a7a6d5e36d2bd0d181` |
| `sponsor.html` | `7834f782539ee2e9cdee30b08383e8a32c132782c0c1e0a7fdaa2ec1cd2e15a3` |
| `privacy.html` | `31b39f9c35ffcc027e98ae9b547ba0e4d6cf1a2887a3aa1cbaf07f2532131896` |
| `terms.html` | `8d56cbdba2c4aa813d8361ca4f5fdd26eb11232c546818399c1042d0d1c6bfd5` |

## 未完成

- 爱发电主页尚未创建，赞助页仍是「正在创建中」，没有真实收款入口。
- DMG 尚未上传到官网下载区；当前仍通过赞助者私下发送。
- 赞助页文案中的回馈边界需在爱发电主页创建后再次核对。
