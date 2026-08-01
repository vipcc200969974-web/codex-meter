<div align="center">

# Codex Meter

一个放在 macOS 菜单栏里的 Codex 额度小表。

[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](#系统要求)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](Package.swift)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

</div>

Codex Meter 会读取本机 Codex 会话日志，推断当前 5 小时额度和周额度，并把最关键的信息放在菜单栏里：

```text
61% | 3h08m
```

它没有后端，也不会请求网络。适合像我这样经常开着 Codex，又想随手看一眼额度还剩多少的人。

本项目纯 vibe coding：从真实使用场景出发，把 Codex 额度做成一个轻量、直观、常驻的菜单栏状态。

## 界面预览

![Codex Meter 面板预览](https://raw.githubusercontent.com/HappyChenchen/codex-meter/main/docs/images/panel-preview.png?v=0.1.0)

菜单栏状态会跟随 5 小时剩余额度变色：

![Codex Meter 用量颜色状态](https://raw.githubusercontent.com/HappyChenchen/codex-meter/main/docs/images/quota-states.svg?v=0.1.0)

## 它能做什么

- 在菜单栏显示 5 小时额度和恢复倒计时
- 在弹出面板里查看周额度
- Codex 写入本机日志后通常在 1–3 秒内刷新，60 秒轮询作为兜底
- 在弹出面板中查看今日 Token 总量、缓存输入、非缓存输入、输出和推理明细
- 用组成进度条查看缓存、非缓存和输出的比例
- 手动刷新额度
- 额度较低时发本地通知
- 可选语音播报，支持 1 / 5 / 10 分钟间隔
- 只读取本地日志，不上传内容

## 安装运行

先把代码拉到本地：

```sh
git clone https://github.com/HappyChenchen/codex-meter.git
cd codex-meter
```

构建 app：

```sh
./scripts/build-app.sh
```

启动或重启：

```sh
./scripts/restart.sh
```

构建后的 app 会出现在：

```text
build/Codex Meter.app
```

你也可以直接用 Swift Package 跑：

```sh
swift run CodexMeter
```

## 数据从哪里来

Codex Meter 会扫描这些本地目录：

```text
~/.codex/sessions
~/.codex/archived_sessions
```

额度数据只读取日志中的结构化 `payload.rate_limits` 记录，用来推断：

- 5 小时窗口额度
- 7 天窗口额度
- 对应的恢复时间

今日 Token 用量只读取 `payload.type == "token_count"` 记录中的 `payload.info.last_token_usage` 字段，用来汇总今日总量、缓存输入、非缓存输入、输出和推理明细。

Codex Meter 不读取或上传对话内容，也不读取或上传认证信息；所有汇总都在本机完成，不会发起网络请求。

如果刚启动时看不到额度，通常是本机还没有写入可用的 Codex 会话日志。打开一次 Codex 会话后再刷新，一般就会有数据。

## 项目结构

```text
.
├── Package.swift
├── README.md
├── LICENSE
├── scripts/
│   ├── build-app.sh
│   └── restart.sh
└── Sources/
    └── CodexMeter/
        └── CodexMeterApp.swift
```

代码目前故意保持得很小，没有拆成很多层。这个项目的目标是把事情做好，而不是把一个菜单栏小工具写成框架。

## 系统要求

- macOS 14 或更新版本
- Swift 6 工具链
- 本机有 Codex 会话日志

## 常见问题

**菜单栏没有出现？**  
先运行 `./scripts/restart.sh`。如果菜单栏空间太挤，macOS 也可能把它藏起来。

**额度看起来不准？**  
额度是从本地日志推断出来的，不是官方实时 API。日志延迟或格式变化时，短时间不准是可能的。

**为什么不提供 DMG？**  
这个项目更适合直接给代码和脚本。DMG 没有签名、公证时，别人安装反而容易遇到 macOS 拦截。

## 隐私

Codex Meter 只在本机读取 JSONL 日志文件，不上传会话内容，不读取认证信息，也不发网络请求。

## 许可证

[MIT](LICENSE)

## 说明

这个项目不是 OpenAI 官方项目。菜单栏里的额度只代表本地日志推断结果，可能和服务端真实状态有短暂差异。
