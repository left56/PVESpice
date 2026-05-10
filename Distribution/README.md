# 分发与 GitHub Releases

预编译 **macOS arm64** 的 zip **不提交到本仓库**，请在 [GitHub Releases](https://github.com/left56/PVESpice/releases) 下载对应版本附件。

## 维护者：打 zip 并发布

1. 确保已生成 `Vendor-macos-arm64/` 并能通过 `./build_release.sh` 成功构建。  
2. 在仓库根目录执行：

```bash
./Scripts/package-macos-release.sh
```

会在 **`Distribution/macos-arm64/`**（已被 `.gitignore` 忽略）生成  
`PVESpice-<MARKETING_VERSION>-macos-arm64.zip`。

3. 将 `MARKETING_VERSION` 与 Git tag 对齐（例如 `0.1.0` 对应 tag **`v0.1.0`**），推送 tag：

```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

4. 在 GitHub 上 **Draft a new release**（或已有 tag 则 **Create release from tag**），选择 `v0.1.0`，上传上一步的 zip 作为 **Release asset**。  
   若已安装 [GitHub CLI](https://cli.github.com/)：

```bash
gh release create v0.1.0 ./Distribution/macos-arm64/PVESpice-0.1.0-macos-arm64.zip \
  --title "PVESpice 0.1.0" \
  --notes "macOS 14+，Apple Silicon (arm64)。解压得到 PVESpice.app。"
```

将版本号、zip 路径与说明按实际版本替换即可。

## 若远端仍含已删除的大文件历史

若曾把 zip 推上过 `main`，回退本地提交后需对远端执行（**会改写历史**，协作者需重新拉取）：

```bash
git push --force-with-lease origin main
```
