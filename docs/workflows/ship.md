# Ship loop（固定链）

**唯一入口（本地/Agent）**：`bash scripts/ship.sh`  
**唯一云端链（GitHub）**：`Precheck` → `Auto Tag` → `Release`

```
改代码
  → bash scripts/bump-version.sh --patch   # 或手改 prop + CHANGELOG
  → 编辑 CHANGELOG 条目
  → bash scripts/ship.sh -m "Release vX.Y.Z"
  → （Origin 无 gh）daily_env1 同步 GitHub main
  → Actions 自动：Precheck 绿 → 轻量 tag → Release.yml → immutable zip
  → （可选）机内：apps.sh hot-update <release.zip> && status → aligned=1
```

## 硬规则（已固化进 workflow）

| 规则 | 实现 |
|------|------|
| 红构建不打 tag | Auto Tag 只在 **Precheck success** 的 `workflow_run` 后跑 |
| tag 不连锁 Release | Auto Tag 内 `gh workflow run Release.yml --ref tag` |
| 轻量 tag | `git tag v*`（禁 annotated，避免 workflows 403） |
| versionCode 单调 | Auto Tag 对比已发布 asset 号段 |
| 失败可见 | Auto Tag **等待** Release 结束；Release 红则 Auto Tag 红 |
| Action pin | `module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33` |

细则 → `.cursor/skills/release/SKILL.md` · 台账 → `docs/CLOUD_RELEASE.md`。
