# Cell to Singularity - 自定义勘探活动模组 & 编辑器

为《Cell to Singularity》添加自定义勘探活动：加载自定义树状勘探包（`tree.json` + PNG 素材），
使用**游戏原生的勘探界面与逻辑**（`EventController` / `LteServer`），并配套一个 LÖVE2D 的勘探树编辑器。

## 仓库结构

```
CustomEventPack/CustomEventPackPlugin.cs   模组主程序（活动注册、包加载、导入浏览器）
FontReplacerPlugin.cs                      中文字形替换（依赖 StreamingAssets/zh-cn.ttf）
CustomEventPackEditor/                     LÖVE 11.5 勘探树编辑器
    main.lua                               编辑器主程序（含「发布 ZIP」）
    src/pack.lua                           包模型 + Pack.exportZip()（Linux）
    src/selftest.lua                       自测（发布构建中排除）
patcher/                                   Mono.Cecil IL 补丁器（读 patches.txt）
ilfold/                                    把插件类型折叠进 Assembly-CSharp
ilcheck/、lister/                          IL 检查 / 枚举辅助工具
build_customeventpack.sh                   构建插件 DLL
launch_modded.sh                           补丁 → 折叠两个插件 → 启动
package_editor_win.sh                      打包编辑器 Windows 发布
patches.txt、refs.rsp                       IL 补丁指令 / 编译引用
```

## 构建

```sh
bash _mod_tools/build_customeventpack.sh     # 构建 CustomEventPackPlugin.dll
bash _mod_tools/launch_modded.sh dwproton    # 补丁+折叠+启动
bash _mod_tools/package_editor_win.sh        # 打包编辑器
```

发布物由 `_mod_tools/dist/` 产出（已 gitignore）：

- `CellToSingularityMod-win64.zip` - 模组（含 `zh-cn.ttf` 中文字体）
- `CellToSingularityEditor-win64.zip` - 编辑器

## 关键约束

- **两个插件 DLL 必须一起折叠**（CustomEventPackPlugin + FontReplacerPlugin）。
  只折叠一个会让 Steam 启动与命令行启动行为不一致，且中文变方块。
- **Managed/CustomEventPackPlugin.dll 不能删除** —— 折叠后的元数据引用该程序集作用域，
  删除会引发约 12,000 条 TypeLoadException。
- **StreamingAssets/zh-cn.ttf 是字体插件的唯一文件依赖**，只在该路径下查找。
- 编辑器**不要 require("lfs")** —— LÖVE 11.5 不带该模块。
- 发布构建保持 src/build.lua 的 release = true，排除 src/selftest.lua，
  --selftest / --smoketest 由 not RELEASE 把关。
- 活动奖励解析为原版「罗吉特」(Logit) 货币（PrizeType.Doober / stat_doober），
  不降级包声明的 prizeType 语义。

## git 忽略说明

只跟踪源码与脚本。忽略的均为本地产物或不可复现内容：

bin/ obj/ out/ dist/（构建与发布产物）、dll_backups/（游戏程序集快照 721 MB）、
devhome/ home/（Proton 测试用的临时 HOME）、decomp/（ilspycmd 全量反编译 10 MB）。
