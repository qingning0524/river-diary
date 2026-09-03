# 数据管道与云端建议

## 本地优先

`data/raw.json` 是唯一原始快照；不要直接编辑 `data/data.json`。

```bash
python3 build.py
python3 -m unittest discover -s tests
```

构建会：

1. 合并 `src/css` 与 `src/js` 到运行用的 `css/style.css`、`js/app.js`。
2. 校验并清洗 `data/raw.json`。
3. 生成网页单文件 `dist/index.html`。
4. 把清洗后的数据同步到 iOS `Resources/data.json`。

## 是否上云

建议先保持本地优先，后续如果要多设备使用，再加一个最小同步层：

- 存储：CloudKit private database 最适合个人健康/情绪数据；数据仍归用户 iCloud 账号。
- 数据形状：云端保存 `raw.json` 版本化记录，每次更新带 `generated`、`schemaVersion` 和内容 hash。
- 冲突：按天合并，不要整文件覆盖；用户本地评分和 HealthKit 聚合始终保留设备端副本。
- 隐私：云上不保存原始浏览域名和聊天对象；同步前先清洗成聚合统计。

如果只是 iOS 端自己采集和查看，不需要云；如果网页和 iOS 都要成为真实数据入口，CloudKit 是比自建服务器更合适的起点。
