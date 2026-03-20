# AwakeSequoia

macOS Sequoia 的森林壁纸在正常桌面上只是一张静态图片，动态效果仅在锁屏界面出现。

基于 Apple 系统内置的 Sequoia 壁纸资源（Metal shader、.usdc 网格模型、.exr 渐变纹理），对锁屏的动态森林效果进行了复现。

## Download

[Releases](https://github.com/zzf1955/AwakeSequoia/releases) 

## Requirements

- **macOS 14 (Sonoma)** or later
- Apple Silicon or Intel Mac with Metal support

## Build & Run

```bash
swift build
swift run AwakeSequoia --live

# Or build .app bundle
bash bundle_app.sh
open AwakeSequoia.app
```

## Smooth Transition Setup

将第一帧设为静态桌面壁纸，可以实现从静态到动态的无缝过渡：

1. 启动 AwakeSequoia
2. 点击菜单栏树图标 → **Save Desktop Image**
3. `AwakeSequoia.png` 保存到桌面
4. **系统设置 → 墙纸**，选择这张图片
5. 动态壁纸会从完全相同的画面开始播放

注意 mac 的切换动画会根据文件名缓存文件。

## Menu Bar Controls

- **Speed** — 摄像机移动速度
- **Sway / Sway Speed** — 摄像机摇摆幅度和频率
- **Frame Rate** — 30 / 60 FPS
- **Save Desktop Image** — 保存第一帧到桌面

全屏应用激活时自动暂停，回到桌面时自动恢复。
