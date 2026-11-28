# Ship loop（固定链）

**本地唯一入口**：`bash scripts/ship.sh`  
**云端唯一链**：`Precheck` → `Auto Tag` → `Release`  
**同步**：Origin 无 `gh` → Cursor **`daily_env1`** 推 GitHub `main`

```
改代码
  → bash scripts/bump-version.sh --patch   # 或手改 prop + Cargo + CHANGELOG
  → 编辑 CHANGELOG 条目（禁止留 stub）
  → bash scripts/ship.sh -m "Release vX.Y.Z (versionCode N)"
  → daily_env1 同步 GitHub main（若本环境无 gh）
  → Actions：Precheck 绿 → 轻量 tag → Release.yml → immutable zip
  → （可选）OP12：curl Release zip → apps.sh hot-update → status aligned=1
```

## 硬规则（已进 workflow）

| 规则 | 实现 |
|------|------|
| 红构建不打 tag | Auto Tag 只接 **Precheck success** 的 `workflow_run`（且 `main` + `push`） |
| tag 不连锁 Release | Auto Tag 内 `gh workflow run Release.yml --ref tag` |
| 轻量 tag | `git tag v*`（禁 annotated → workflows 403） |
| versionCode 单调 | 对比已发布 asset `ksu-bgfreeze-N-` |
| 失败可见 | Auto Tag **等待** Release；红则整链红 |
| Action pin | `module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33` |

## Agent 检查清单

- [ ] `module.prop` 与 `daemon/Cargo.toml` 版本一致  
- [ ] `CHANGELOG.md` 有 `## vX.Y.Z` 实条目  
- [ ] `ship.sh` 已 push Origin  
- [ ] GitHub `main` 已含同一 tip  
- [ ] Actions：Precheck / Auto Tag / Release 全绿  
- [ ] `gh release view vX.Y.Z` → `isImmutable: true` + 单个 zip  

细则 → `.cursor/skills/release/SKILL.md` · 台账 → `docs/CLOUD_RELEASE.md` · 热更 → `module/AGENTS.md`。
