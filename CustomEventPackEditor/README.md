# CustomEventPackEditor — 自定义勘探活动包可视化编辑器

LÖVE 11.5 (Lua) 桌面程序，用来可视化编辑《Cell to Singularity》的外置自定义勘探活动包
（`tree.json` + `pack.json` + `icons/<uid>.png`）。

* 纯 Lua + LÖVE 11.5 API，**没有任何外部依赖**（JSON 编解码器是自己写的，见 `src/json.lua`）。
* 不联网、不写注册表、不改游戏文件；只在用户点「保存」时写回包目录里的
  `tree.json` / `pack.json`，以及「选择图标」时复制 PNG 到 `icons/`。

---

## 运行

```bash
# 在仓库根目录（也就是包含 CustomEvents/ 的那一层）
love _mod_tools/CustomEventPackEditor

# 无界面自检：JSON 往返 + 包读写 + 校验规则，打印 PASS/FAIL 后退出
love _mod_tools/CustomEventPackEditor --selftest

# 冒烟测试：真的开窗口跑 72 帧，模拟点击/拖动/建包/删节点，截图到本目录后退出
love _mod_tools/CustomEventPackEditor --smoketest

# 纯 lua 跑同一套自检（不需要 LÖVE）
cd _mod_tools/CustomEventPackEditor && lua tests/roundtrip.lua
```

启动时会扫描这些目录里的活动包（每个子目录里有 `tree.json` 就算一个包）：
`<工作区>/CustomEvents`、`<工作区>/StreamingAssets/CustomEvents`，
以及 Unity 的 persistentDataPath 三个常见位置。也可以用左侧「按路径打开」直接输入目录。

---

## 界面

| 区域 | 说明 |
|---|---|
| 顶部 | 新建 / 打开 / 保存 / 另存为，三个视图页签（图谱、活动设置、校验），右侧是侧栏 / 检查器 / 帮助开关 |
| 左侧栏 | 扫描到的活动包列表 + 按路径打开 |
| 中间 | 节点图谱画布（或活动设置 / 校验视图） |
| 右侧 | 选中节点的检查器 |
| 底部 | 状态栏：上一步操作、当前文件路径、节点数、错误/警告数、当前字体 |

### 快捷键

| 按键 | 作用 |
|---|---|
| `Ctrl+S` / `Ctrl+Shift+S` | 保存 / 另存为 |
| `Ctrl+O` / `Ctrl+N` / `Ctrl+R` | 打开 / 新建 / 重新扫描 |
| `Ctrl+D` | 复制当前节点 |
| `Tab` / `Ctrl+B` | 显示隐藏 检查器 / 侧栏 |
| `F1` / `Esc` | 帮助面板（列出全部快捷键） |
| `Delete` | 删除选中节点（并清理所有引用它的前置与特效） |
| 方向键 | 微调 1 个世界单位（Shift = 10） |
| 左键拖动节点 | 移动，默认吸附到 1 个世界单位；按住 Shift 为 0.1 精细 |
| 左键拖动空白 | 框选（Shift 加选）；Shift+左键点节点 = 加选 |
| 中键 / 右键 / 空格+左键拖动 | 平移画布（拖动） |
| **W A S D** | **平移画布**：W 上 / A 左 / S 下 / D 右。速度是**屏幕像素/秒**，任何缩放级别手感一致；
| | 按住 **Shift** 快 3 倍；基础速度可在「活动设置 → 编辑器设置 → 画布平移速度」调整（存进 editor.cfg 的 `pan_speed`） |
| 滚轮（光标在画布上） | 以光标为中心缩放画布；画布上那个世界坐标保持不动 |
| 滚轮（光标在面板上） | 滚动**光标下那个**列表；到顶/到底后自动冒泡给外层页面 |
| **Ctrl + 滚轮** | **缩放整个编辑器界面 0.75x–2.0x**（光标下的那一行 / 画布上的那一点保持不动） |
| **Shift + 滚轮** | 面板可横向滚动时左右滚动（校验列表、pack.json 预览），否则照常上下滚动 |
| 拖动滚动条 / 点击滚动条轨道 | 拖动或跳转；纵向、横向滚动条都支持 |
| `Ctrl+F` 或画布右下角「适应」 | 画布缩放以适应全部节点 |
| 画布右下角 −/＋ | 画布缩放（和滚轮等效） |

WASD 只在**没有文本框获得焦点**时平移画布：有焦点时字母照常输入到输入框（和空格键同一条规则），
按住 Ctrl 时 W/A/S/D 也不平移（Ctrl+D 复制节点等快捷键不受影响），方向键微调节点的功能保持不变。
WASD 用的是和鼠标拖动完全相同的那一个相机变量与世界坐标（`camx/camy/zoom`），位移按
`speed * dt / zoom` 计算，所以与 UI 缩放 0.75/1.0/1.5 以及任意画布缩放都无关。

滚轮修饰键是用 `love.keyboard.isDown("lctrl","rctrl","lgui","rgui")` 和
`love.keyboard.isDown("lshift","rshift")` 读的，不依赖滚轮事件本身带的修饰信息，
所以 Ctrl+滚轮 / Cmd+滚轮 在任何平台都一样。

滚轮事件本身**只提供滚动量**（LÖVE 的 `love.wheelmoved(x, y)` 的 x/y 是位移，不是光标坐标）。
光标位置只有一个来源：`ui.pointer()`，它由 `love.mousemoved` 更新、每帧再用
`love.mouse.getPosition()` 刷新，并且只经过 `ui.setPointer()` **换算一次**成面板矩形所在的
逻辑坐标。命中测试（`computeWheelTarget`）、滚动应用（`beginScroll`）、画布缩放和
Ctrl+滚轮锚点用的都是这一个来源，不存在物理/逻辑混用。

### 界面缩放（UI scale）

* `Ctrl+加号` / `Ctrl+减号` 调整，`Ctrl+0` 复位；也可以点「活动设置」页顶部的
  **编辑器设置** 卡片（−/＋/重置 + 75% / 100% / 125% / 150% / 200% 预设）。
* 范围 0.75x – 2.0x。面板宽度、控件尺寸、间距、字号一起缩放；字体是用
  `love.graphics.newFont(fileData, size x scale)` **按缩放后的像素尺寸重新栅格化**的
  （另有缓存），不是把位图拉大。
* 窗口不够宽时面板会自动让位：先隐藏左侧栏，再压缩检查器，最后才隐藏检查器，
  画布始终保留最小宽度 —— 任何情况下面板都不会互相重叠。
* 设置会写进程序目录下的 `editor.cfg`（纯 key=value 文本，可随时删除）：

  ```
  # CustomEventPackEditor settings (safe to delete)
  inspector=true
  last_pack=/path/to/CustomEvents/SamplePack
  sidebar=true
  ui_scale=1.25
  view=graph
  ```

---

## 滚动

每一个会长高的列表都有**自己的**滚动区域（鼠标滚轮 + 可拖动滚动条 + 点击轨道跳转，
偏移量始终被夹在 0..内容高度 之间）：

* 活动设置页：整页、任务 missions（8 组 x 4 个任务也不会跑出屏幕）、
  货币 currencies、本地化 localization、开场白 intro、结束语 outro
* 节点检查器整列
* 校验结果列表
* 文件选择框的目录列表、左侧活动包列表、下拉框弹出的长列表

滚轮只作用于光标下的那一个区域（取最内层），该区域已经到顶/到底时会冒泡给外层，
所以嵌在页面里的任务列表滚到底之后整页仍然可以继续滚。

---

## 画布上体现的格式约束

* 节点画成圆（半径随缩放变化），有 `icons/<uid>.png` 就画图标，否则画类型占位色：
  Generator 绿、Research 蓝、Trophy 金。
* 前置连线按 `lineType` 画：`NONE` 虚线、`NORM` 实线、`THICK` 粗线、`SPECIAL` 金色，
  `hidden` 会半透明。选中节点时，它的 `effects` 用紫色虚线画出来。
* 淡网格 + 以 `startNode` 为锚点的**游戏可见区域框（100 × 58 世界单位）**，
  一眼就能看出树会不会超出屏幕。
* 新节点默认落在下一层：`y = 层数 × 22`，x 在 ±22 之间之字形，并自动连一条
  `requiredCount = 0` 的前置到当前选中的节点。
* `requiredCount > 0` 会在检查器和校验面板里给出醒目警告（>0 时节点在玩家拥有足够前置前
  根本不出现）；`requiredCount = 0` 才是「整棵树开局可见」。
* `cost` / `production` 允许写成裸数字，但保存时一律写完整的 `a`..`h` 八个字段。

---

## 校验规则（`src/validate.lua`）

错误：uid 重复 / uid 为空 / startNode 不存在 / 前置或特效指向不存在的节点 / `nodes` 为空 /
missions 结构错误。
警告：`requiredCount > 0`、节点离起始节点超过 150 世界单位、y 为负、自环、重复前置、
缺少标题、`currencyCount` 与 `currencies` 数量不符、任务字段取值未知。
提示：缺少图标、x 超出 ±40、孤立节点、cost 全 0、没有写 intro。

点任意一条问题会跳到对应节点（或切到活动设置视图）。

---


### 任务的多个收集目标（targets）

一个任务可以有多个收集目标，全部满足才算完成（游戏里每个 target 展开成一个 Mission，同一张卡里的
Mission 必须 TrueForAll(collected)）：

```json
{ "type": "Collect",
  "targets": [ { "item": "deepsea_sonar", "amount": 20 },
                 { "item": "deepsea_rov",   "amount": 10 } ],
  "prizeType": "Darwinium", "prizeID": "5", "prizeAmount": 5 }
```

编辑器里每个任务都有一份**收集目标列表**：每行 = 节点下拉框（item）+ 数量 + 删除按钮，
下面有「＋ 收集目标」；只有一个目标时删除按钮不可用。

**保存形式（向后兼容）**：

* 只有 **1 个**目标 → 写回旧版扁平字段 `reqItemId` / `reqAmount`，**不写** `targets`；
  用户没有动过的任务完全不会被改写，老包保存后仍然一模一样。
* **2 个及以上** → 写 `targets` 数组，并删掉 `reqItemId` / `reqAmount`。
* 卡片数量仍然只看 `prizeType` + `prizeID`（同一阶段内相邻且相同才算一张），所以一个 3 目标的
  任务仍然只算**一个**任务条目。

校验会警告：target 的 `item` 不是本包节点 uid（永远不会完成）、`amount <= 0`、以及 item 为空。

### 自定义背景图片（backgrounds）

把游戏里的树截图 / 参考美术图垫在画布后面，方便对着它摆节点。

    "backgrounds": [
      { "file": "backgrounds/ref1.png", "x": 0, "y": 0, "scale": 1.0,
        "opacity": 1.0, "visible": true, "locked": false }
    ]

* file 相对活动包目录；图片放在包的 backgrounds/ 子目录里（面板的「＋ 添加背景图片」会打开文件
  浏览器选 png/jpg，并**复制**进这个目录，重名自动加 _2、_3）。
* x / y 是世界坐标里图片**左上角**的位置（和节点一样 +y 向上），scale 是相对原始像素的缩放，
  opacity 0..1，visible、locked 控制显示与锁定。
* 数组顺序就是图层顺序：**越靠后越在上面**。
* 条目里不认识的键会原样保留（和任务字段一样）；没有背景的包**不会**写出 backgrounds 键。
* **游戏注入器完全忽略这个键**，它只是给编辑者用的元数据，不影响游戏表现。

**Ctrl+B 进入 / 退出背景编辑模式**（焦点在文本框里时不会触发；左侧活动包列表的开关改成
Ctrl+Shift+B）。进入后：

* 画布左上角显示「背景编辑模式 (Ctrl+B 退出)」，状态栏和画布图例也会提示；
* **左键拖动图片**就是移动选中的背景，点击可切换选中的图片；此时**节点不能选中也不能拖动**；
* 退出后恢复原来的节点操作，背景不再响应左键。

左侧面板（在背景编辑模式出现，可滚动）：

| 控件 | 作用 |
|---|---|
| 列表 | 点击选中；显/隐 切换 visible，锁/开 切换 locked，^/v 调整图层顺序，x 移除条目（文件保留） |
| ＋ 添加背景图片 | 选图并复制到 backgrounds/，追加一条并选中 |
| x / y | 选中图片左上角的世界坐标 |
| scale / opacity | 缩放与不透明度 |
| 适应画布 | 缩放到刚好铺满当前视图并居中 |
| 归零 | x / y 复位为 0 |

缺文件、scale <= 0、opacity 不在 0..1 之间都会在校验面板里给出警告；读不到的图片在画布上画成
红色占位方框，不会崩。

### 文本框编辑键

所有文本框（节点 uid/标题/说明、检查器数字框、任务字段、货币、本地化、intro/outro、pack id/title、
路径框、新建包对话框）都支持完整编辑键：

* `Backspace` 删除光标前一个字符，`Delete` 删除光标后一个字符，`Home`/`End` 跳到行首/行尾，
  `←`/`→` 按**一个字符**移动光标；
* **UTF-8 感知**：中文等一个多字节字符整体删除/整体跨越，绝不会切断字节序列；
* 按住 `Backspace` 会连续删除（LÖVE 的 key repeat 已打开）；
* `Ctrl+Backspace` / `Ctrl+Delete` 按词删除；光标位置在文本变短后会自动收敛到合法范围。

### 节点形状

| 类型 | 形状 | 颜色 |
|---|---|---|
| `Generator` | 圆形 | 绿 |
| `Research` | 六边形 | 蓝 |
| `Trophy` | 星形 | 金 |

图标仍然裁在形状内部（stencil），选中高亮、类型配色、标签位置都跟着形状走；
画布左下角的图例和右侧检查器标题都显示同一个形状。**点击判定用形状的外接圆**（半径 r）：
所有形状都内接在这个圆里，所以画出来的东西一定点得到，点击行为和以前完全一致。

### 任务面板上的条目数量（唯一要对得上的数字）

**任务编辑器顶部那行就是玩家在任务面板上看到的数量**，格式和游戏一致：
`游戏中任务面板显示：2 个任务条目 (0/2)`（`UIRank.RefreshView()` 里是
`completed + "/" + RequiredMissionGroups()`，而 `RequiredMissionGroups()` = `missionGroups.Count`）。

用词：pack.json 里的 `missions` 叫**任务阶段**，任务面板上的每一条叫**任务条目**。
编辑器里**不会**再用「级 / 等级」称呼阶段，避免把阶段数当成屏幕上的条目数。

两条规则决定面板上到底有几条：

* **面板一次只显示一个阶段。** `MissionController` 只把当前 rank 的 missions 交给
  `RefreshMissionGroups()`。进入活动时是第 1 个阶段；插件在运行期补上了原本缺失的推进逻辑，
  当前阶段的全部任务条目完成后会切到下一个阶段（`currentRank = rankRule[idx+1]`，同时刷新
  `rankLevel` 与 `_missions`），所以包里写的每个阶段都会被玩到。
* **相邻且奖励相同的任务会并成一个条目。** `prizeType` 与 `prizeID` **都相同**且**相邻**的任务
  算一条，中间隔着别的奖励就不会合并。

编辑器里的呈现：

* 顶部最大的一行：**`游戏中任务面板显示：N 个任务条目 (0/N)`** —— 进入活动时（第 1 个阶段）
  玩家看到的数量，唯一可以对账的数字。
* 每个阶段的标题行同时给出收集目标总数：`阶段 1 · 3 条任务 / 4 个收集目标 → 3 个任务条目（游戏中首先显示）`。
* 每个阶段一行，按顺序解锁：`阶段 1 · 2 条任务 → 2 个任务条目（游戏中首先显示）`、
  `阶段 2 · 2 条任务 → 2 个任务条目（完成阶段 1 后进入）`、
  `阶段 3 · 2 条任务 → 2 个任务条目（完成阶段 2 后进入）`；当前阶段用高亮边框，
  后面的阶段变暗，表示「还没轮到」而不是「不会显示」。
* 编辑器里不再显示任何可能被误读成「屏幕上数量」的合计；阶段数只在提示与校验面板里出现。
* 鼠标悬停有两条规则的完整说明。

---

## 代码结构

| 文件 | 职责 |
|---|---|
| `conf.lua` | 窗口配置（可缩放、stencil、vsync） |
| `main.lua` | 应用外壳：状态、布局、事件路由、快捷键、状态栏、模态框、冒烟测试 |
| `src/json.lua` | 从零实现的 JSON 编解码器（UTF-8 直通、\uXXXX、代理对、数组/对象区分、确定性键序） |
| `src/pack.lua` | 包模型：目录扫描、加载与归一化、保存、节点增删改、图标管理 |
| `src/graph.lua` | 画布：相机、缩放、网格、可见区域框、连线、节点绘制、拖动与框选 |
| `src/inspector.lua` | 节点检查器面板 |
| `src/settings.lua` | 活动设置视图（pack.json、intro/outro、货币、本地化、任务编辑器） |
| `src/validate.lua` | 校验规则 |
| `src/ui.lua` | 立即模式控件库（按钮、文本框、多行文本、数字框、下拉、复选、滚动区、提示） |
| `src/fonts.lua` | 中文字体探测（/mis/zh-cn.ttf → NotoSansCJK → wqy → DroidSansFallback）+ 字号缓存 |
| `src/filebrowser.lua` | 内置文件/文件夹选择框（LÖVE 没有原生对话框） |
| `src/config.lua` | editor.cfg 读写（key=value，缩放值归一化） |
| `src/selftest.lua` | 无界面测试套件（`--selftest` 与 `tests/roundtrip.lua` 共用） |
| `tests/roundtrip.lua` | 纯 lua 入口 |

---

## 验证

```bash
cd _mod_tools/CustomEventPackEditor
luac -p $(find . -name '*.lua')     # 语法检查（系统 luac 是 5.4，比 LuaJIT 更严格）
lua tests/roundtrip.lua             # 86 项检查
love . --selftest                   # 同一套检查走 LÖVE
love . --smoketest                  # 开窗口跑 16 项交互断言 + 截图
```

冒烟测试会生成 `smoketest*.png`（图谱、活动设置、校验、帮助、文件框、报错视图），
可以直接打开看效果。

---

## 已知限制

* 保存时 `cost`/`production` 会展开成完整 `a`..`h`（格式要求），所以**文本层面**与
  只写了 `{"a":15}` 的原文件不同，但按游戏语义（缺省字段 = 0）完全等价；
  JSON 层面的 decode → encode → decode 是严格深相等的。
* 未知字段（例如 missions 里的 `prizeID`、节点上的自定义键）会原样保留并写回。
* 没有撤销/重做；文件选择框是自己实现的，路径里带单引号的目录无法浏览（会提示）。
* 双击、右键菜单、拖拽文件进窗口都没有做。
* 帮助面板、检查器宽度固定；检查器宽度不可拖动。
