# 本机开发签名与钥匙串授权

## 症状

每次打开 River Diary 都要在钥匙串对话框里输入好几次登录密码（每个条目一次）。

## 原因

`macos/RiverDiaryMac/make_app.sh` 默认用 **ad-hoc 签名**（`codesign --sign -`）。
ad-hoc 程序没有稳定的开发者身份，钥匙串条目的 ACL 只能绑定到具体的二进制指纹；
**每次重新构建，指纹都变，已有授权全部失效**，于是每个条目都会重新弹密码框。

River Diary 在钥匙串里有多类条目：

| 服务 | 用途 |
|---|---|
| `RiverDiaryMac.state` | 日记加密密钥与包装密钥（2 个条目） |
| `RiverDiary.account` | 会话、客户端实例、资料归属绑定、待撤销令牌 |
| `local.riverdiary.node` | 本机复制设备身份 |

所以一次启动可能连续弹 5–7 次。

## 解决：用开发者证书做稳定签名

本机已有 `Apple Development: …` 证书时，改用：

```bash
make mac-signed
```

该目标会自动找到 Apple Development 证书并传给 `make_app.sh`；也可以手动：

```bash
CODESIGN_IDENTITY="Apple Development: 8618068726037 (DFY38H9827)" make mac
```

稳定签名的 designated requirement 是「bundle id + 证书 CN」，
**重新构建不会改变它**，钥匙串授权因此可以长期保留。

## 第一次切换后的操作

1. 打开 `dist/River Diary.app`；
2. 每次弹出钥匙串对话框时输入 **macOS 登录密码**，点 **「始终允许」**（不是「允许」）；
3. 最多 7 次，之后正常启动不再询问。

## 注意

- 不要同时用多个副本（Xcode 构建产物、`dist`、`/Applications`）打开同一个 bundle id：
  未签名/每次重签的副本会再次触发授权。
- 检查签名是否稳定：

  ```bash
  codesign -dv --verbose=2 "dist/River Diary.app" 2>&1 | grep Authority
  ```

  应显示 `Authority=Apple Development: …`，而不是 `Signature=adhoc`。
- 对外分发仍需要 Developer ID 签名、公证与安装包验证，本机开发证书不能替代。
