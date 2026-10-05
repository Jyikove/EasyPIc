# EasyPic 本机签名与文件夹授权

## 更新后为何再次询问“下载”权限

开发版原先使用 `codesign --sign -` 临时签名。其 designated requirement 绑定当前程序的代码哈希，更新代码后身份要求改变，系统可能重新询问文件夹权限。固定 Bundle ID 本身不能解决这个问题。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

EasyPic 为前后浏览和缩略图读取当前图片所在文件夹；识别 Apple Live Photo 时也需要查找配套视频。所以从 Finder 打开一张下载图片后，系统可能询问整个下载文件夹的访问权限。当前用户已确认：授权后同一版本正常，仅更新后重新出现。

## 配置固定开发签名

本机目前没有有效的代码签名证书。可使用 Xcode 与 Apple Account 创建本机开发证书，个人开发与测试可使用免费 Personal Team；Developer ID 公证和对外分发是另外的流程。[Apple 账户能力说明](https://developer.apple.com/support/compare-memberships/)。

1. 安装并打开 Xcode，在 `Xcode → Settings → Accounts` 中登录自己的 Apple Account。
2. 选择个人团队或已有团队，点击 `Manage Certificates`，通过 `+` 创建 `Apple Development` 证书。登录、双重认证以及协议确认由用户本人完成。[Apple 的证书配置步骤](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)。
3. 回到 EasyPic 项目运行 `./scripts/build.sh`。若只有一个有效的 Apple 开发/Developer ID 签名身份，脚本会选择并记住它。
4. 从旧的临时签名切换到证书签名后，首次访问下载文件夹仍可能需要再次允许；后续更新保持同一签名身份、Bundle ID 和兼容的 designated requirement。

构建脚本将选定证书的 SHA-1 指纹保存到 `.local/signing-identity`，此目录不会上传 GitHub。证书与私钥由系统钥匙串管理，不放入项目。若有多个证书，指定完整证书名称或指纹：

```sh
EASYPIC_SIGN_IDENTITY='Apple Development: 你的证书名称' ./scripts/build.sh
```

也可将有效证书的 SHA-1 指纹写入 `.local/signing-identity`，以后无需设置环境变量。指定证书缺失/过期或没有私钥时，脚本会停止，不会默默切回临时签名。有多个证书但尚未指定时，也会停止，避免每次选中不同身份。

没有配置证书时仍可用临时签名运行；每次更新后，在系统提示中重新允许即可。此模式的权限持续性问题尚未解决。`EASYPIC_SIGN_IDENTITY=-` 可以明确选择临时签名。
