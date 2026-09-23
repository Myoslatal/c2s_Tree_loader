# Cell to Singularity - 自定义勘探活动模组

为《Cell to Singularity》添加自定义勘探活动：加载自定义树状勘探包（tree.json + PNG 素材），
使用**游戏原生的勘探界面与逻辑**（EventController / LteServer），奖励解析为原版「罗吉特」货币。

## 安装

把本压缩包里的 CellToSingularity_Data/ **整个覆盖**到游戏安装目录：

    <Steam>/steamapps/common/Cell to Singularity/
        CellToSingularity_Data/
            Managed/
                Assembly-CSharp.dll          <- 已打补丁并折叠了插件
                CustomEventPackPlugin.dll    <- 必需，勿删
                FontReplacerPlugin.dll       <- 必需，勿删
            StreamingAssets/
                zh-cn.ttf                    <- 中文字体，必需
            CustomEvents/                    <- 勘探包放这里

**重要：**

1. Managed/CustomEventPackPlugin.dll 与 FontReplacerPlugin.dll 必须与 Assembly-CSharp.dll
   同目录。折叠后的元数据引用这两个程序集作用域，删除会导致约 12,000 条 TypeLoadException。
2. StreamingAssets/zh-cn.ttf 是字体替换插件的唯一文件依赖，它通过
   TMP_FontAsset.CreateFontAsset(<该路径>) 直接读取该 TTF 提供中文字形。
   缺失时中文显示为方块/空白。该文件**只在 StreamingAssets/ 下被查找**，改名或移动都会失效。

## 还原原版

原版备份/Assembly-CSharp.dll 是未改动的游戏原文件，复制回
CellToSingularity_Data/Managed/Assembly-CSharp.dll 即可卸载。

## 导入勘探包

1. 游戏内点击「自定义勘探活动」打开模组窗口
2. 点「导入 ZIP」打开文件浏览器
3. 找到勘探包的 .zip，点「导入」
4. 解压到 CustomEvents/ 并自动重启游戏

压缩包顶层必须是包目录本身（MyPack/tree.json...），解压后即得 CustomEvents/MyPack/。
用配套的「勘探编辑器」里的「发布 ZIP」即可产出符合该结构的压缩包。
导入成功后原 .zip 会被删除，临时 imported/ 文件夹也会被清掉。

## 勘探包结构

    CustomEvents/<包名>/
        pack.json          包元数据（标题、货币数、开场/结束台词）
        tree.json          勘探树（节点、成本、产出、特效、前置）
        banner.png  button.png  resource.png  currency1.png ...
        icons/  backgrounds/

进度独立保存在 <persistentDataPath>/CustomEventSaves/<包名>.explorer.json。
