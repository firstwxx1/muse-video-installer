# Muse 视频工作台 · 一键安装（firstwxx1 版）

![Version](https://img.shields.io/badge/版本-v1.5.0-blue)
![Fork](https://img.shields.io/badge/基于-yys9253462--gif%2Fmuse--video--installer-green)

> 在**你自己的服务器**上，一条命令装好一个「输入文字就能生成视频」的网页工具。
> 装完后：浏览器打开网址 → 写一句话 → 出视频。还能让别的软件（Cherry Studio、NextChat 等）连上它调用接口。

**不需要懂 Linux，不需要懂 Docker。** 脚本会自己把该装的都装好。

---

## 目录

- [这个版本改了什么](#这个版本改了什么)
- [装之前要准备什么](#装之前要准备什么)
- [30 秒开始安装](#30-秒开始安装)
- [终端实录](#终端实录)
- [装完之后怎么用](#装完之后怎么用)
- [常用命令](#常用命令)
- [遇到问题怎么办](#遇到问题怎么办)
- [关于](#关于)

---

## 这个版本改了什么

本仓库 fork 自 [yys9253462-gif/muse-video-installer](https://github.com/yys9253462-gif/muse-video-installer)（原版 v1.1.1），迭代记录：

**v1.5.0 · 终端控制面板 + 装完即用 + 多账号**

装完敲一个 `muse` 就进控制面板，加账号、看状态、管账号池、拿直达链接全在里面：

```
   Muse 视频工作台  ·  控制面板
    网页：   https://muse.example.com/
    账号池： 2 个 muse.ai 账号

    1) 添加 muse.ai 账号（浏览器登录，可连着导多个）
    2) 工作台直达链接（带 Key，点开即用）
    3) 账号池管理（列出 / 删除 / 测活）
    4) 运行状态
    5) 升级到最新版
    6) 重新配置并安装（沿用数据）
    7) 卸载
    0) 退出
```

| 变化 | 说明 |
|---|---|
| **终端控制面板** | 安装时自动装入 `muse` 命令，敲它就进面板；所有常用操作不再需要记参数 |
| **登录完直接能用** | 终端打印「直达链接」（带 `?key=&api=`）——点开网页自动填好接口地址和 Key，状态灯直接变绿。不用再手抄 Key，也不会再出现「Key 无效」那种抄错的坑 |
| **一条链接导多个账号** | 导号窗口 15 分钟内可连着导：导完一个在网页点「再导一个」，换个 muse.ai 账号登录，终端会依次报出每一个 |
| **账号池管理** | 新增 `--accounts`：列出（含状态 / 已用次数 / 有效期）、`--remove <编号>` 删除、`--test` 逐个验证会话是否还有效 |
| **不再堆重复账号** | 同一个 muse.ai 邮箱重复导入时，自动更新已有那条的 cookie，不再新增；列表里也会把重复条目标出来并给出清理命令 |
| **`--status` 修好了** | 之前账号数那行因为接口字段名对不上，从来不显示（空账号池的提醒也从不触发）——现在正常显示，并附带直达链接 |

**v1.4.2 · 域名模式把 API 也一起反代**

域名站点块（caddy）现在同时反代 `/v1/*` 到接口端口 —— 网页走域名时，页面里的接口地址直接填同源 `https://你的域名` 即可，无跨域无混合内容。同时修复：重跑安装时不认识自家 caddy 容器、误报「80/443 被别的程序占着」的问题（现在会热更新 Caddyfile）。

**v1.4.1 · 修复：投屏窗口能看不能点**

真机首测发现导号窗口画面正常但鼠标键盘全部无效。根因：CDP 通道多个线程抢读同一条 WebSocket，输入指令的响应被收帧线程吃掉、全部超时。修复为读写分离（单 pump 线程按 id 路由响应、事件进队列），并补上鼠标 `buttons` 状态位。

**v1.4.0 · 终端一键导号（一条命令出链接，免 Key）**

```bash
sudo bash /opt/mvw/install.sh --add-account
```

敲完这一条，终端会打印一个**一次性导号链接**——在自己电脑的浏览器里打开它，网页里直接出现登录窗口（不用填 Key、不用点按钮），登录 muse.ai 的瞬间 cookie 自动进账号池，终端这边同步显示「✓ 导入成功：你的邮箱」。

| 特性 | 说明 |
|---|---|
| **免 Key** | 链接里带一次性令牌（15 分钟有效、导入成功即作废），不用再翻 API Key |
| **自动开窗** | 带令牌的页面加载即自动启动登录窗口，零点击 |
| **终端联动** | 服务器终端实时等待并显示导入结果；Ctrl-C 退出等待不影响链接有效性 |
| **安全** | 令牌与网页分离存放（宿主机 `./runtime` 卷双向通道），用过即焚、过期自动清理 |

**v1.3.0 · 一键导号（网页里登录，零本机依赖）**

原版导入 muse.ai 账号要在你自己的电脑上装 Python、下载脚本、手填服务器地址和 Key、弹浏览器登录。现在整个流程搬进了一个网页：

| 老流程（v1.1.x） | 新流程（v1.3.0 起） |
|---|---|
| 本机装 Python | 不用装任何东西 |
| 下载 `get_muse_cookie.py` | 不用下载 |
| 手填服务器地址 + API Key | v1.3.0 粘贴一次 Key；v1.4.0 起连 Key 都不用 |
| 本机弹浏览器登录 | 登录窗口就在网页里（服务器无头 Chromium 实时投屏） |

用法：`sudo bash install.sh --add-account` 拿链接（v1.4.0），或直接打开 `http://你的服务器IP:18620/` 粘贴 Key（v1.3.0 方式，仍然可用）。cookie 抓取和入库全部在服务器上自动完成。

**v1.2.0 · 端口自动检测与自动切换**

| 改动 | 说明 |
|---|---|
| **指定端口被占 → 自动换** | 原版遇到 `--api-port` 指定的端口被占会直接报错退出；现在会警告一句并自动挑一个空闲的，不再卡住 |
| **真实 bind 检测** | 判定端口空闲时往 `0.0.0.0` 真绑一次再释放，消除「检查时空闲、启动时被抢」的时间窗 |
| **停止容器也算占用** | 端口扫描覆盖 `docker ps -a`（含已停止容器的发布端口），避免它下次启动时撞车 |
| **端口互不撞车** | 接口/网页/导号三个端口互相排斥，绝不选成同一个 |
| **密集占用自动逃逸** | 连续 50 个端口都被占时跳到高位段（20000-61000）随机找，不再傻扫 |

其余行为（安装流程、卸载/升级命令）与原版一致。

---

## 装之前要准备什么

| 需要 | 说明 |
|---|---|
| **一台服务器** | Linux（Debian / Ubuntu / CentOS / RHEL / Alpine 都行），能 SSH 登录，有 root 权限 |
| **至少 2 核 4G** | 因为要跑一个无头浏览器。内存小了会卡 |
| **至少 10G 空闲磁盘** | 程序本体 + 浏览器大约几百 MB |
| **能访问外网** | 第一次安装要从 GitHub 下载程序，网速慢会久一点 |
| **两个端口** | 默认用 `18610`（接口）和 `8090`（网页）。被占了会**自动换**，本版本的核心改进 |
| **一个 muse.ai 账号** | 这是"燃料"。装完必须导入一个账号才能生成视频 |

> ⚠️ **端口要在云服务商控制台放行**
> 阿里云 / 腾讯云 / AWS / Oracle 等都有"安全组"或"防火墙规则"。
> 装完如果网页打不开，九成是这里没放行网页端口和接口端口（以安装结束时打印的为准 —— 端口被占时脚本会自动换，放的行要跟最终端口对上）。

---

## 30 秒开始安装

SSH 登录到你的服务器，然后：

```bash
# 1. 下载安装脚本
curl -fsSL -o install.sh https://raw.githubusercontent.com/firstwxx1/muse-video-installer/main/install.sh

# 2. 跑起来（会问你 1-2 个问题）
sudo bash install.sh
```

> 📌 **脚本下载不下来（GitHub 被墙）？** 用镜像前缀包一层：
>
> ```bash
> curl -fsSL -o install.sh https://gh-proxy.com/https://raw.githubusercontent.com/firstwxx1/muse-video-installer/main/install.sh
> ```
>
> 或者用 `scp` 把 `install.sh` 传到服务器：`scp install.sh root@你的服务器IP:/root/`

> ✅ 装完之后**你下载的那份 `install.sh` 删掉也没关系** —— 脚本会把自己
> 另存一份到安装目录里（如 `/opt/mvw/install.sh`），以后 `--status` /
> `--upgrade` / `--uninstall` 都用那一份。

想**全自动、不问任何问题**：

```bash
sudo bash install.sh --yes
```

想**先看看它会做什么、但不动系统**：

```bash
sudo bash install.sh --dry-run
```

---

## 终端实录

**① 安装**（v1.5.0）

```text
$ sudo bash install.sh

  ╭──────────────────────────────────────────────────────╮
  │  Muse 视频工作台 一键安装                              │
  ╰──────────────────────────────────────────────────────╯

  我在帮你装一个「输入文字就能生成视频」的网页工具。
  只会问你 1-2 个问题。拿不准的直接按回车，用默认值就行。

▸ 开始检查环境
  ✓ 系统：ubuntu 24.04（用 apt 装东西）
  ✓ docker 已就绪（29.8.2）
▸ 准备程序文件
  ✓ 下载完成
▸ 配置密钥
  ✓ 沿用上次的密钥（客户端不用重配）
▸ 写入配置
  ! 端口 18610 已被占用，自动换一个          ← v1.2.0 起：不再报错退出
  ✓ 配置完成：接口端口 18611，网页端口 8090

════════════════════════════════════════════════════════
  装好了！下一步只要做一件事：导入你的 muse.ai 账号
════════════════════════════════════════════════════════

  ① 先打开网页看看
     http://你的服务器IP:8090/

  ② 导入 muse.ai 账号（必须先做这步，否则生成不了）
     在终端里敲这一条：
        sudo bash /opt/mvw/install.sh --add-account
     它会给你一条链接 —— 在你自己电脑的浏览器里打开，
     网页里出现登录窗口，登录 muse.ai 就导入完成了。
     不用装 Python、不用下载工具、不用填 Key。
     一条链接能连着导多个账号（导完一个，在网页上点「再导一个」）。

  ③ 回到网页，输入一句话测试
     用这条直达链接打开，接口地址和 Key 会自动填好：
        https://你的域名/?key=m2a_xxxx...&api=https://你的域名

  以后要加账号、看账号池、再拿这条链接，直接在终端敲： muse

  常用命令：
    muse                            终端控制面板（加账号 / 管账号池 / 拿链接）
    sudo bash /opt/mvw/install.sh --add-account 导号：生成登录链接（可连着导多个账号）
    sudo bash /opt/mvw/install.sh --link        工作台直达链接（带 Key，点开即用）
    sudo bash /opt/mvw/install.sh --accounts    账号池管理（列出 / 删除 / 测活）
```

**② 控制面板** —— 装完敲 `muse` 就进（忘了参数时的不二入口）

```text
$ muse

  ══════════════════════════════════════════════
   Muse 视频工作台  ·  控制面板
  ══════════════════════════════════════════════
    网页：   https://muse.example.com/
    账号池： 1 个 muse.ai 账号

    1) 添加 muse.ai 账号（浏览器登录，可连着导多个）
    2) 工作台直达链接（带 Key，点开即用）
    3) 账号池管理（列出 / 删除 / 测活）
    4) 运行状态
    5) 升级到最新版
    6) 重新配置并安装（沿用数据）
    7) 卸载
    0) 退出

  请选择 [0-7，回车=0]: 1
```

**③ 导号 —— 一条链接，连导多个**

```text
▸ 生成导号链接

  在你自己电脑的浏览器里打开这个链接：

      https://muse.example.com/import/?token=0c8163c1fef8bd80ad4414ce010a789c

  · 打开后网页里会出现登录窗口，在里面登录 muse.ai 就行，导入全自动
  · 一个链接 = 一个 15 分钟的导号窗口，可以连着导多个账号：
    导完一个在网页上点「再导一个」，换个 muse.ai 账号继续登录即可
  · 这里会一直等并依次报出每个导入的账号；结束按 Ctrl-C，不影响已导入的

    等待浏览器里完成登录… 00:47（Ctrl-C 退出等待）
  ✓ 导入成功：first@mail.com（账号池现有 1 个）
    想再加一个？在刚才那个网页点「再导一个」，换个 muse.ai 账号登录 ——
    这里会自动接着报；再等 90 秒没有新的就结束。
    本次已导入 2 个账号 · 还可以继续导，结束按 Ctrl-C
  ✓ 导入成功：second@mail.com（账号池现有 2 个）

  工作台直达链接（接口地址和 Key 都已经带在里面，点开即用）：

      https://muse.example.com/?key=m2a_xxxx...&api=https://muse.example.com

  再管账号就敲：sudo bash /opt/mvw/install.sh --accounts
```

**④ 账号池管理**

```text
$ sudo bash /opt/mvw/install.sh --accounts

  账号池：2 个账号

   #   邮箱 / 标签         状态   已用 有效期至    ID
   1   first@mail.com      正常   3    2026-10-06  d256f34290f8
   2   second@mail.com     正常   0    2026-10-06  250b09137b3a

  删账号：  sudo bash /opt/mvw/install.sh --accounts --remove <编号>
  测会话：  sudo bash /opt/mvw/install.sh --accounts --test   （真开浏览器，每个 10-30 秒）
```

> 💡 上面安装那一步里 `18610` 被别的程序占了，脚本自动换到 `18611` 继续装 ——
> v1.1.1 及之前在这里会直接报错让你重跑。**给 `--api-port` / `--web-port`
> 显式指定的端口被占也一样自动换**，并且会打印清楚换到了哪个。

---


## 装完之后怎么用

装完直接在服务器终端敲：

```bash
muse
```

进控制面板 —— 加账号、看状态、管账号池、拿直达链接都在里面，不用记参数。

### 第 1 步：打开网页看看

浏览器访问**直达链接**（终端面板选 2，或 `sudo bash /opt/mvw/install.sh --link` 打印）：

```
https://你的域名/?key=m2a_xxxx&api=https://你的域名
```

打开后接口地址和 API Key 会自动填好，右上角状态灯直接变绿。（直接开 `http://IP:8090/` 也行，但那样得手动填一次 Key。）

### 第 2 步：导入 muse.ai 账号（必做）

```bash
sudo bash /opt/mvw/install.sh --add-account
```

1. 终端打印一条链接（15 分钟有效）—— 复制到你自己电脑的浏览器打开
2. 网页里自动出现实时登录窗口（跑在服务器上的无头浏览器，画面投屏过来）
3. 在里面登录 muse.ai —— cookie 自动进账号池，终端同步显示「✓ 导入成功：邮箱」
4. **想接着导下一个**：在网页上点「再导一个」，换个 muse.ai 账号登录即可 ——
   终端会依次报出每一个（一条链接就是一个 15 分钟的导号窗口）
5. 导完终端会打印**工作台直达链接**（带 Key），点开就能直接生成

> 💡 其他方式仍然可用：直接开 `http://你的服务器IP:18620/` 手动粘贴 Key 导入（v1.3.0 方式）；
> 或本机 Python 跑上游的 `tools/get_muse_cookie.py`（v1.1.x 老方式）。
> 如果链接打不开，先查云安全组有没有放行导号端口（默认 18620，被占过会自动换，以安装输出为准）。

### 第 3 步：生成

回到网页，写一句描述，点生成。1-2 分钟出片。

### 管账号池

```bash
sudo bash /opt/mvw/install.sh --accounts              # 列出（状态 / 已用次数 / 有效期）
sudo bash /opt/mvw/install.sh --accounts --remove 2   # 删掉第 2 个
sudo bash /opt/mvw/install.sh --accounts --test       # 逐个验证会话还有没有效
```

同一个 muse.ai 邮箱重复导入**不会**堆出多条 —— 会自动更新已有那条的 cookie。列表里如果看到重复条目（老版本导入留下的），会标出来并给出删除命令。

### 接给其他软件

Cherry Studio / NextChat 等支持 OpenAI 风格接口的软件都能连：

- 接口地址：`http://你的服务器IP:接口端口/v1`（域名有配反代的话也可以用 `https://你的域名`）
- API Key：安装结束时给你的那把（`--status` 随时能看回来）

---

## 常用命令

| 我想… | 命令 |
|---|---|
| 进控制面板 | `muse` |
| 看状态（找回地址和 Key） | `sudo bash install.sh --status` |
| 拿工作台直达链接（带 Key） | `sudo bash install.sh --link` |
| 添加 muse.ai 账号（可连着导多个） | `sudo bash install.sh --add-account` |
| 账号池：列出 / 删除 / 测活 | `sudo bash install.sh --accounts [--remove N] [--test]` |
| 升级 | `sudo bash install.sh --upgrade` |
| 卸载 | `sudo bash install.sh --uninstall` |
| 看容器日志 | `cd /opt/mvw && docker compose -p mvw logs -f` |
| 看网页日志 | `journalctl -u mvw-web.service -f` |
| 看谁占端口 | `sudo ss -lntp \| grep <端口>` |
| 全自动安装 | `sudo bash install.sh --yes` |
| 干跑预演 | `sudo bash install.sh --dry-run` |
| 指定端口/目录 | `sudo bash install.sh --api-port 18610 --web-port 8090 --dir /opt/mvw` |

---

## 遇到问题怎么办

| 症状 | 解法 |
|---|---|
| **装完网页打不开** | 先确认云服务商**安全组**放行了最终打印的那两个端口（端口被自动换过的话要以最终值为准），再用 `--status` 核对地址 |
| **脚本下载不下来** | GitHub 被墙，用上面镜像前缀的 curl 命令，或 scp 传上去 |
| **程序本体 clone 失败** | 服务器到 GitHub 不通。给 git 配代理，或手动把 muse2api 的代码解压到 `/opt/mvw` 再重跑 |
| **给了 `--domain` 但域名打不开** | 多半是 DNS 还没生效。等解析到位后重跑 `sudo bash install.sh --domain 你的域名` 会自动配 HTTPS |
| **新装起不来，报 address pools** | Docker 网段被分光了。`docker network prune -f` 清掉没人用的网络再试 |
| **想改端口重装** | 直接重跑加 `--api-port` / `--web-port`。**API Key 会沿用**，客户端不用改 |

---

## 关于

- 本仓库：[firstwxx1/muse-video-installer](https://github.com/firstwxx1/muse-video-installer) ——
  基于 [yys9253462-gif/muse-video-installer](https://github.com/yys9253462-gif/muse-video-installer) v1.1.1，
  叠加 v1.2.0 端口自动检测与自动切换改进
- 程序本体：[yys9253462-gif/muse2api](https://github.com/yys9253462-gif/muse2api)
  —— 基于上游 [czg86389-hub/muse2api](https://github.com/czg86389-hub/muse2api)（MIT 协议），
  叠加了 11 项稳定性与安全修复
- 安装脚本版本：`1.5.0`

### v1.3.0 一键导号的实现要点

改动细节都在 `import_sidecar.py` 的注释里。摘要：

```text
import_sidecar.py  FastAPI 服务，复用 mvw 镜像（chromium + uvicorn 都在，零额外下载）
画面投屏           CDP Page.startScreencast → JPEG 帧 → 浏览器 <img>
输入回传           鼠标/键盘事件 → Input.dispatchMouseEvent / dispatchKeyEvent
自动抓号           轮询 Storage.getCookies，hatch_sess 一出现即抓全量 cookie
自动入库           POST /admin/accounts（Bearer Key，与原版导号工具同一接口）
鉴权               网页不含密钥；WebSocket 必须带 ?key=<MUSE2API_KEY> 比对才放行
```

### v1.2.0 端口逻辑的五个来源

改动细节都在 `install.sh` 的注释里（含为什么 bind 测试用裸 bind 不开
SO_REUSEADDR —— Windows 上它允许端口劫持，语义不可依赖）。摘要：

```text
resolve_port()    显式指定端口被占 → 警告 + 自动换，不再 die
port_bindable()   0.0.0.0 裸 bind 真实探测（依赖 python3，安装时自动装）
used_ports()      ss 宿主监听 + docker ps -a 全容器发布端口
pick_port()       逐个上探 → 50 连败跳高位随机段 → 500 次上限兜底
端口互斥          接口口与网页口 exclude，绝不选重
```

> 💡 **免责声明**：本脚本只是部署工具，视频生成能力来自 muse.ai 的账号。
> 请遵守 muse.ai 的服务条款，不要滥用。
