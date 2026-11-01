# KeyMute（键默）

只锁**本地物理键盘**的 macOS 菜单栏小工具：触控板、屏幕、远程注入的按键一切照常。

- 擦键盘 / 防误触
- 远程接管（UU 远程等）时把本地键盘彻底锁死
- 无 Dock 图标、无窗口、无轮询，只有一个 `CGEventTap`

## 构建与运行

```bash
make            # 编译 + 组装 build/KeyMute.app + ad-hoc 签名
make run        # 启动（菜单栏出现键盘图标）
make install    # 装到 /Applications
make clean
```

首次启动后到「系统设置 → 隐私与安全性 → 辅助功能」勾选 KeyMute（或点菜单里的
「⚠︎ 需要辅助功能权限…」直接跳转）。授权后菜单图标会自动变成键盘；若仍显示未授权，
退出重开一次 App。

> 不装 Xcode 本体也可以，只需命令行工具与 macOS SDK。

### 固定签名（避免每次重编都重新授权）

ad-hoc 签名的「指定要求」是二进制的 cdhash，每次重编都变，TCC 就当成换了个 App，
已授予的辅助功能权限全部失效。所以这里用一把**固定的自签 key** 签名：

```
scripts/signing/keymute-dev.key.pem    # 明文私钥（本机资产，不入库）
scripts/signing/keymute-dev.cert.pem   # 自签证书
scripts/signing/keymute-dev.p12        # 上面两个打包，固定密码 keymute
```

首次 clone 后跑一次 `make cert` 生成这三个文件（已 gitignore，不进仓库）。

构建时 `scripts/ensure-sign.sh` 把 p12 导入**项目内**的钥匙串文件
`.signing/build.keychain-db`（gitignore，密码固定 `keymute`），并授权 codesign
直接使用私钥 —— 不碰登录钥匙串、不弹密码框、可随时删除重建。

签名后的「指定要求」是 `identifier "com.pingfury.keymute" and certificate leaf = H"..."`，
重编不变，所以**辅助功能授权只需一次**。

- 换证书：删掉 `scripts/signing/keymute-dev.*` 后跑 `make cert`（会换 leaf，需重新授权一次）
- 想临时回到 ad-hoc：`make SIGN=`
- 私钥只在本机，不要提交；换机器要重新 `make cert` 并重新授权一次

## 使用

菜单栏图标：`keyboard`（空闲）/ `lock.fill`（锁定中）/ `exclamationmark.triangle`（未授权）。
自动解锁剩余不足 60 秒时，图标旁显示剩余秒数。

```
键盘已锁定 · 00:42 · 10:00 后自动解锁
────────────────────────
✓ 锁定键盘                              ⇧⌘K
  自动解锁  ▸  5 / 10 / 30 分钟 / 永不
✓ 允许远程输入（UU 远程）
✓ 全局快捷键 ⇧⌘K
  同时锁定触控板（即将支持）
────────────────────────
  诊断日志…
────────────────────────
关于 KeyMute
退出
```

设计约束（刻意如此）：

- **锁定期间不提供任何键盘解锁方式**——否则抹布一压就解了。解锁只靠鼠标/触控板，或等自动解锁。
- **退出即恢复**：进程消失 tap 就消失，键盘立刻恢复，不需要恢复逻辑。
- 锁定期间用 `ProcessInfo.beginActivity` 顶住息屏与睡眠，远程才不断线。
- 全局快捷键 ⇧⌘K **只负责锁定**；解锁仍需鼠标（可用菜单项关掉快捷键）。

## 诊断（P0 分流点）

菜单 →「诊断日志…」：

> 按键事件**只在锁定期间**记录（tap 只在锁定时存在）；未锁定时面板只显示生命周期事件。

- 每条记录：`时间 | 类型 | 按键 | keycode | pid | 事件源 | 来源进程 | → 吞掉/放行`
- 「注入测试按键」：App 自己用私有事件源注入一个 `a`，来源 PID 是本进程。**锁定时它必须仍然生效**——这就是 F4（远程输入放行）的等价验证，不需要开远程软件。
  （若注入事件没出现在日志里，说明该系统上 session 级 tap 看不到自注入事件，此时以 UU 远程实测为准。）
- 「暂停记录 / 继续记录」「清空」

判读规则：

| 现象 | 结论 |
|---|---|
| 本地键盘：`pid=0`、`src=hid` | 应被吞掉 ✅ |
| UU 远程注入：`pid≠0` | 应放行 ✅ |
| **UU 远程注入也是 `pid=0`** | A 方案失效 ❌ → 需转 HID 独占方案 |

## 验收清单

- [ ] 锁定后本地打字无反应，F1/F2（亮度）与音量键同样无效
- [ ] 锁定后触控板、鼠标完全正常，能点菜单栏解锁
- [ ] 锁定期间屏幕不黑、系统不休眠
- [ ] 诊断面板「注入测试按键」在锁定时仍能打出 `a`
- [ ] UU 远程在锁定时打字正常
- [ ] 自动解锁到点自动解除
- [ ] `kill -9` 掉进程后键盘立刻恢复
- [ ] 系统设置里取消勾选辅助功能 → 菜单显示需要权限，且不会谎报"已锁定"

## 已知边界（非目标）

- 不做安全用途：登录窗口、锁屏、Secure Input 输入框拦不住
- 只能活在用户会话里，锁屏后 tap 无效
- 其他工具（Alfred / Karabiner / 文本扩展）**注入**的按键会被放行，这是"只放行非硬件来源"的必然副作用
- 只锁全部物理键盘，暂不支持"仅锁内置键盘"（需 HID 层设备识别）
- 触控板锁定未实现（与"必须能点菜单栏"冲突，需菜单栏区域白名单）

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| 锁定期间触控板/鼠标点不动 | 事件 tap 回调超时，主线程被拖住 | 回调里不能做 UI；诊断面板已改为 10Hz 批量渲染 |
| 日志显示"放行"但目标 App 收不到输入 | 同上：tap 超时后当前事件被系统丢弃 | 看诊断里的 `tap 因回调超时被系统禁用` 提示，正常应始终为 0 次 |
| 打字跑到别处 / 目标 App 无反应 | 诊断窗口抢了焦点 | 面板已改非激活窗口；也可先点回目标 App |
| 授权后仍显示未授权 | TCC 需重启进程生效 | 退出重开一次 App |
| ⇧⌘K 无效 | 被其他 App 占用 | 诊断日志会记录注册失败；可关掉该项用菜单操作 |

## 结构

| 文件 | 职责 |
|---|---|
| `Sources/main.swift` | NSApplication 装配（accessory 策略） |
| `Sources/AppDelegate.swift` | 启动、单实例、生命周期 |
| `Sources/KeyboardLockService.swift` | tap 生命周期（仅锁定期间存在）、事件过滤、抬键保护、看门狗、自动解锁、防休眠 |
| `Sources/HotkeyManager.swift` | 全局快捷键 ⇧⌘K（Carbon，不依赖 tap） |
| `Sources/StatusBarController.swift` | NSStatusItem + 菜单 + 1s 刷新 |
| `Sources/PermissionGate.swift` | 辅助功能授权检查与引导 |
| `Sources/Diagnostics.swift` | 事件入队（回调内）+ 格式化（回调外）、注入自测 |
| `Sources/DiagnosticsPanel.swift` | 诊断窗口（非激活、10Hz 批量渲染） |
| `Sources/Preferences.swift` | UserDefaults |
| `Resources/Info.plist` | `LSUIElement=YES`、固定 bundle id、`CFBundleIconFile`、min macOS 13.0；版本只有 `CFBundleShortVersionString`（去掉 `CFBundleVersion` 后关于面板不再显示 `(1)`，将来做自动更新再加回来） |
| `Resources/AppIcon.icns` | App 图标（`make icon` 由 `scripts/gen-icon.swift` 生成） |
| `scripts/signing-cert.sh` | 生成仓库里的固定签名身份（明文 PEM/P12） |
| `scripts/ensure-sign.sh` | 构建前把 p12 导入项目内钥匙串，静默授权 codesign |
| `scripts/gen-icon.swift` | 用 SF Symbols 渲染 App 图标 |

## 实现约束（改代码前必读）

1. **tap 只在锁定期间存在**：`lock()` 创建，`unlock()` 立即移除。空闲时零干扰、零权限开销。
   因此未锁定时诊断面板只能记录生命周期事件，按键记录只在锁定期间产生。
2. **tap 回调必须是极快路径**：只允许整数字段读取 + 结构体入队。
   禁止在回调里做：UI 更新、字符串拼接/格式化、`NSRunningApplication` 查询、文件 I/O。
   回调超时会被系统禁用并**丢弃当前事件**（表现为"日志说放行、App 收不到"），同时卡住整个会话输入管线（表现为"触控板点不动"）。
3. **诊断渲染走 10Hz 定时器**：`Diagnostics.flush()` 在回调之外格式化，面板批量追加，
   文本视图开启 `allowsNonContiguousLayout` 并限长，避免长日志重排拖慢主线程。
4. **诊断窗口不激活 App**（`nonactivatingPanel` + `becomesKeyOnlyIfNeeded`），避免抢焦点导致"输入进了诊断窗口"。
