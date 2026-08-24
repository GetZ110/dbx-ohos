# 鸿蒙应用「沉浸式三键」学习笔记

> 学习来源：`devecocli docs`（本地 DevEco 文档库）与华为开发者文档。
> 本文整理「沉浸式 + 三键导航栏」的核心概念、API、实现方式与避让适配，并对照本项目（dbx-ohos，Web 组件 + 2in1 目标）。

## 一、核心概念

- **三键导航栏**：系统底部导航的一种形态，包含【返回 / 主页 / 任务】三个虚拟按键。用户可切换为「导航条」或「手势导航」。
- **避让区（AvoidArea）**：沉浸式布局下，系统界面元素（状态栏、导航栏/三键区、挖孔区）所在的区域。避让区之外的区域叫**安全区**。
- **沉浸式**：让应用内容延伸到状态栏 / 导航区，成为视觉焦点，消除系统 UI 的割裂感。

## 二、实现沉浸式的三种思路

| 思路 | 手段 | 适用 |
|---|---|---|
| 隐藏系统界面元素 | `setWindowLayoutFullScreen(true)` + `setSpecificSystemBarEnabled(...)` | 游戏、影音、相机大图 |
| 沉浸式布局 + 布局避让 | `setWindowLayoutFullScreen(true)` + `getWindowAvoidArea` + padding | 办公、通用页面（保留系统 UI） |
| 组件安全区扩展 | `expandSafeArea` / `background` / `ignoreLayoutSafeArea` | 页面级 / 组件级沉浸 |

> 关键判断：`isImmersiveLayout()` 可查当前窗口是否沉浸式布局。

## 三、核心 API（@ohos.window）

- `windowStage.getMainWindowSync()` / `getMainWindow()` — 获取应用主窗口
- `setWindowLayoutFullScreen(true|false)` — 进入/退出沉浸式布局（非自由窗口）
- `setSpecificSystemBarEnabled('status' | 'navigation' | 'navigationIndicator', boolean)`
  - 全屏主窗口下控制**状态栏 / 三键导航栏 / 底部导航条** 显隐
- `setWindowSystemBarEnable(['status','navigation'])` / `[]` — 状态栏/底部导航显隐。
  - ⚠️ 注意：只对 `status` 生效，`navigation` 参数**无效果**（文档明确说明）
- `setWindowDecorVisible(false)` — 隐藏窗口标题栏 → 进入沉浸式（**自由窗口状态**）
- `setWindowDecorHeight(h)` — 设置标题栏高度（自由窗口时控制右上角三键区高度）
- `setWindowTitleButtonVisible(max, min, close)` — 隐藏标题栏右上角三键（PC/2in1）
- `getWindowAvoidArea(AvoidAreaType)` — 获取避让区
- `on('avoidAreaChange')` — 监听避让区变化（旋转/形态切换/折叠屏等）
- `setWindowBackgroundColor` — 设置窗口背景色
- `setTitleAndDockHoverShown` / `maximize(...)` — 全屏模式下标题栏与 Dock 热区

### AvoidAreaType 枚举
- `TYPE_SYSTEM` — 系统状态栏
- `TYPE_NAVIGATION_INDICATOR` — 底部导航区（三键区）
- `TYPE_CUTOUT` — 挖孔区
- （计算方式：把窗口按对角线分为四象限，元素中心落在哪个象限就写入对应 Rect）

## 四、三键导航的「监听与避让」（重点）

三键导航的位置、形态可能变化（横屏时在侧边等），需监听并动态避让：

```ts
import settings from '@ohos.settings';

// 1. 监听三键导航变化
settings.registerKeyObserver(hostContext, 'float_navigation_info',
  settings.domainName.USER_PROPERTY, () => { this.adaptLayout(); });

// 2. 读取导航信息
settings.getValue(hostContext, 'float_navigation_info',
  settings.domainName.USER_PROPERTY).then((data: string) => {
    if (data) {
      let info = JSON.parse(data) as NavigationButtonInfo;
      this.adaptValue = info.getAdaptValue();
    }
  });

// 3. 三键信息结构
class NavigationButtonInfo {
  private showType: number = -1; // -1 不显示; 0 三键形态; 1 悬浮球
  private region: number[] = [0,0,0,0]; // [x, y, 三键区宽, 三键区高] px
  getAdaptValue(): number {
    // 横屏时三键在侧边(此时区域宽<高)，适配值取宽度
    if (this.showType === 0 && this.region[2] < this.region[3]) {
      return this.region[2];
    }
    return 0;
  }
}

// 4. 布局避让
.padding({ right: this.getUIContext().px2vp(this.adaptValue) })
```

## 五、PC / 2in1 设备的特殊处理（对应本项目 P2）

本项目目标是 **2in1 / PC 平板**，自由多窗形态下的三键在**右上角标题栏区**，与手机底部三键不同：

1. **隐藏标题栏（保留三键）**：
   ```ts
   mainWindow.setWindowDecorVisible(false); // 隐藏标题栏 → 沉浸式
   mainWindow.setWindowDecorHeight(h);       // 控制右上角三键区高度
   mainWindow.on('windowTitleButtonRectChange', ...); // 监听三键大小变化做避让
   ```
2. **隐藏右上角三键（彻底沉浸）**：
   ```ts
   mainWindow.setWindowTitleButtonVisible(max, min, close); // false 则隐藏对应键
   ```
3. **PC 非全屏隐藏三键**：用 `onMouse` + 定时器判断鼠标静止，静止后隐藏，移动再恢复。
4. **仅全屏时沉浸**：`maximize(MaximizePresentation.ENTER_IMMERSIVE)` + `setTitleAndDockHoverShown`。

> ⚠️ **重要坑**：Window 部分接口虽文档标注支持 PC/2in1，但**部分机型不生效**（如 `setWindowSystemBarEnable` 在 2in1 模拟器中不生效）。开发时务必真机验证，避免影响效率——AGENTS.md 也记录过「最大化后 Dock 仍为系统色」。

## 六、典型完整示例（EntryAbility 全局沉浸 + 避让）

```ts
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', async () => {
      const mainWindow = windowStage.getMainWindowSync();
      await mainWindow.setWindowLayoutFullScreen(true);      // 进入沉浸式布局
      await mainWindow.setSpecificSystemBarEnabled('status', false); // 隐藏状态栏

      // 监听避让区，动态更新
      mainWindow.on('avoidAreaChange', (opt) => {
        if (opt.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate('bottomAvoidHeight', opt.area.bottomRect.height);
        }
      });
    });
  }
}
```

## 七、对本项目（dbx-ohos）的参考价值

- dbx-ohos 的 `Index.ets` 是**全屏 Web** 组件。沉浸式可让 dbx-web 的界面延伸到状态栏/导航区，获得更沉浸的数据库客户端体验，但**必须正确避让**，否则 Web 内容会被系统三键/状态栏遮挡。
- 2in1 目标设备上，若不想默认隐藏三键，至少要在布局时对 `TYPE_NAVIGATION_INDICATOR` 和右上角标题栏三键区做避让。
- Web 组件底部内容（如输入框、按钮）需避开底部导航区，可在 Web 容器外层加 padding / 监听 `avoidAreaChange`。
- 注意接口在 2in1 上的兼容性：优先用真机验证（当前已连 HUAWEI MateBook Pro API 26 2in1）。
