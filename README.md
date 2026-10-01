# Muse 视频工作台 · 一键安装（firstwxx1 版）

![Version](https://img.shields.io/badge/版本-v1.4.0-blue)
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

一次完整的安装长这样（本版本 v1.2.0，含端口被占自动切换的演示）：

```text
$ sudo bash install.sh

  ╭──────────────────────────────────────────────────────╮
  │  Muse 视频工作台 一键安装                              │
  ╰──────────────────────────────────────────────────────╯

  我在帮你装一个「输入文字就能生成视频」的网页工具。
  ...
  只会问你 1-2 个问题。拿不准的直接按回车，用默认值就行。

▸ 开始检查环境
  ✓ 系统：debian 12（用 apt 装东西）
▸ 检查并安装 git / docker / docker compose
  ✓ docker 已就绪（27.1.1）
▸ 准备程序文件
  $ git clone --depth 1 -b 'main' https://github.com/yys9253462-gif/muse2api.git '/opt/mvw'
  ✓ 下载完成
▸ 配置密钥
  ✓ 已生成一把随机密钥（只显示在最后，请留意）
▸ 写入配置
  ! 端口 18610 已被占用，自动换一个      ← v1.2.0：不再报错退出
  ✓ 配置完成：接口端口 18611，网页端口 8090
要不要给网页绑个域名（会自动配 HTTPS）？ [y/N]: n
▸ 启动服务
  ✓ 容器已启动
▸ 等待服务就绪（初次启动要装浏览器，可能 1-2 分钟）
  ✓ 接口服务正常
  ✓ 代码自检：关键修复都在（队列调度 / 鉴权守卫 / 时长校验）
▸ 配置网页服务
  ✓ 网页服务已启动

════════════════════════════════════════════════════════
  装好了！下一步只要做一件事：导入你的 muse.ai 账号
════════════════════════════════════════════════════════

  网页地址：      http://你的服务器IP:8090/
  接口地址：      http://你的服务器IP:18611/v1
  API Key：       m2a_xxxxxxxxxxxxxxxxxxxx
  安装目录：      /opt/mvw
  账号池面板：    http://你的服务器IP:18611/admin?key=你的Key
```

> 💡 上例里 `18610` 被别的程序占了，脚本自动换到 `18611` 继续装 ——
> v1.1.1 及之前在这里会直接报错让你重跑。**给 `--api-port` / `--web-port`
> 显式指定的端口被占也一样自动换**，并且会打印清楚换到了哪个。

---

## 装完之后怎么用

安装结束时会给你这些信息，**请截图保存**（尤其是 API Key）：

```text
网页地址：      http://你的服务器IP:8090/
接口地址：      http://你的服务器IP:18610/v1
API Key：       m2a_xxxxxxxxxxxxxxxxxxxx
安装目录：      /opt/mvw
账号池面板：    http://你的服务器IP:18610/admin?key=你的Key
```

### 第 1 步：打开网页看看

浏览器访问 `http://你的服务器IP:网页端口/`，右上角状态灯是绿的说明接口通了。

### 第 2 步：导入 muse.ai 账号（必做）—— v1.4.0 起一条命令

在服务器终端里敲：

```bash
sudo bash /opt/mvw/install.sh --add-account
```

1. 终端打印一条一次性链接（15 分钟有效）—— 复制到你自己电脑的浏览器打开
2. 网页里自动出现实时登录窗口（跑在服务器上的无头浏览器，画面投屏过来）
3. 在里面登录 muse.ai —— cookie 自动进账号池，终端同步显示「✓ 导入成功：邮箱」
4. 想加第二个账号，再敲一次这条命令拿新链接

> 💡 其他方式仍然可用：直接开 `http://你的服务器IP:18620/` 手动粘贴 Key 导入（v1.3.0 方式）；
> 或本机 Python 跑上游的 `tools/get_muse_cookie.py`（v1.1.x 老方式）。
> 如果链接打不开，先查云安全组有没有放行导号端口（默认 18620，被占过会自动换，以安装输出为准）。

### 第 3 步：生成

回到网页，写一句描述，点生成。1-2 分钟出片。

### 接给其他软件

Cherry Studio / NextChat 等支持 OpenAI 风格接口的软件都能连：

- 接口地址：`http://你的服务器IP:接口端口/v1`
- API Key：安装结束时给你的那把

---

## 常用命令

| 我想… | 命令 |
|---|---|
| 看状态（找回地址和 Key） | `sudo bash install.sh --status` |
| 添加 muse.ai 账号（一次性导号链接） | `sudo bash install.sh --add-account` |
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
- 安装脚本版本：`1.4.0`

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
