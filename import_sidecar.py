#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Muse 视频工作台 · 网页一键导号 sidecar（v1.5.0）

干什么用：
    原版导号要在用户自己的电脑上装 Python、跑脚本、手填服务器地址和 Key。
    这个 sidecar 把「登录 muse.ai」整个搬进网页 —— 它在本容器里起一个无头
    Chromium，把页面画面实时投屏到用户的浏览器（CDP screencast），用户的
    鼠标键盘操作转发回去。用户在里面登录 muse.ai，session cookie 一出现就
    自动抓下来、自动注册进 muse2api 账号池。用户全程只需要一个浏览器。

两条进入路径：
    · ?key=<MUSE2API_KEY>    手动粘贴 Key（老方式，长期有效）
    · ?token=<导号令牌>       install.sh --add-account 在终端生成，15 分钟有效；
                             页面拿到 token 跳过填 Key 直接开窗，终端同时轮询
                             /api/token_status?since=N 显示每一个导入结果

多账号（v1.5.0）：
    · 一条令牌 = 一个 15 分钟的「导号窗口」，期间可以连着导多个账号 ——
      网页里导完一个点「再导一个」即可，终端会依次报出每个账号。
    · 每次成功导入自动把这个窗口续期 15 分钟，连续导号不会中途失效。
    · 同一个 muse.ai 账号重复导入不再堆重复条目：按邮箱匹配，命中就更新
      那一份的 cookie（走 /admin/accounts/{id}/cookies），池子里一个账号只占一行。

安全模型：
    · 网页本身不含任何密钥（连 HTML 都是公开无害的）
    · WebSocket 连接必须带有效 key 或有效令牌；同一令牌同时只允许一个窗口
    · 令牌文件在宿主机 ./runtime 卷上，两边都「读-改-原子替换」
    · cookie 只经本机回环进账号池，不落地、不外发

依赖：复用 muse2api 镜像（chromium + python + fastapi/uvicorn 都在），
    零额外下载。本文件由 install.sh 的 write_importer() 写入安装目录，
    compose 以只读卷挂载进来。
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
import uvicorn

# ── 配置（compose 注入）──────────────────────────────────────────────
API_KEY = os.environ.get("MUSE2API_KEY", "")
API_BASE = os.environ.get(
    "MUSE2API_INTERNAL_BASE",
    # ⚠️ 默认 bridge 网络上容器间没有名字 DNS，但宿主的网关 IP 永远可达，
    #    而 API 发布在 0.0.0.0 上 —— 走网关 IP 即回到本机 API 端口。
    f"http://172.17.0.1:{os.environ.get('MUSE2API_PORT', '18610')}",
)
IMPORT_PORT = int(os.environ.get("IMPORT_PORT", "18620"))
TOKENS_FILE = os.environ.get("TOKENS_FILE", "/runtime/import_tokens.json")
CHROMIUM = os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium")
CDP_PORT = 19999  # 容器内回环端口，不发布
LOGIN_URL = "https://muse.ai/login"
DOMAIN_HINT = "muse.ai"
SESSION_COOKIE = "hatch_sess"     # 登录成功后必然出现的会话 cookie
VIEW_W, VIEW_H = 1280, 800
IDLE_TIMEOUT = 600                # 无操作 10 分钟自动回收浏览器
TOKEN_TTL = 900                   # 导号令牌窗口时长（每次成功导入自动续期）

# ── 极简 WebSocket 客户端（RFC6455 文本帧，stdlib，供 CDP 用）────────
#    与上游 tools/get_muse_cookie.py 里的 WS 同族：容器里没有 websocket-client，
#    自己实现一个够用品。
#
#    ⚠️ 读写分离（v1.4.1 修复的核心）：
#    早期版本让多个线程各自 recv 同一条 socket —— 收帧线程阻塞等画面帧时，
#    输入指令（Input.dispatch*）的响应包会被它当帧吃掉，指令线程永远等不到
#    响应、超时、异常被静默吞掉。表现为：画面活着，点击/键盘全部无效。
#    现在：一个后台 pump 线程独占 recv，带 id 的响应按 id 路由给等待中的
#    call()，无 id 的事件交给注册的 handler。发送端加锁即可多线程并发 call。


class WS:
    def __init__(self, url: str, timeout: float = 15.0):
        assert url.startswith("ws://"), url
        rest = url[5:]
        hostport, _, path = rest.partition("/")
        path = "/" + path
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("WebSocket 握手失败")
            buf += chunk
        if b" 101 " not in buf.split(b"\r\n")[0]:
            raise ConnectionError("WebSocket 握手被拒绝")
        self._id = 0
        self._send_lock = threading.Lock()
        self._pending: dict[int, "queue.Queue"] = {}
        self._handlers = []
        self._closed = False
        # pump 独占 recv；握手完成后转阻塞模式（靠 close() 唤醒），
        # 不能用超时读 —— 超时会在半帧中间炸掉，字节流错位后整个连接就废了。
        self.sock.settimeout(None)
        self._pump = threading.Thread(target=self._pump_loop, daemon=True)
        self._pump.start()

    def on_event(self, handler):
        """注册 CDP 事件回调（在 pump 线程里跑，别在里面做阻塞调用）。"""
        self._handlers.append(handler)

    def _pump_loop(self):
        while not self._closed:
            try:
                msg = self.recv_msg()
            except Exception:
                break
            mid = msg.get("id")
            q = self._pending.pop(mid, None) if mid is not None else None
            if q is not None:
                q.put(msg)
            else:
                for h in list(self._handlers):
                    try:
                        h(msg)
                    except Exception:
                        pass
        # 连接死了：唤醒所有还在等响应的调用者，别让它们傻等到超时
        for q in list(self._pending.values()):
            q.put(None)
        self._pending.clear()

    def _frame(self, payload: bytes):
        head = bytearray([0x81])
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", n)
        mask = os.urandom(4)
        head += mask
        self.sock.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("WebSocket 断开")
            buf += chunk
        return buf

    def recv_msg(self) -> dict:
        payload = b""
        while True:
            b1, b2 = self._read(2)
            fin = b1 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            if b2 & 0x80:  # 服务端→客户端不掩码，防御性处理
                mask = self._read(4)
                data = bytes(x ^ mask[i % 4] for i, x in enumerate(self._read(n)))
            else:
                data = self._read(n)
            payload += data
            if fin:
                return json.loads(payload.decode("utf-8", "replace"))

    def call(self, method: str, params: dict | None = None, timeout: float = 15.0) -> dict:
        with self._send_lock:
            self._id += 1
            mid = self._id
            q: "queue.Queue" = queue.Queue()
            self._pending[mid] = q
            self._frame(json.dumps({"id": mid, "method": method,
                                    "params": params or {}}).encode())
        try:
            msg = q.get(timeout=timeout)
        except queue.Empty:
            self._pending.pop(mid, None)
            raise TimeoutError(f"CDP {method} 超时")
        if msg is None:
            raise ConnectionError("WebSocket 断开")
        if "error" in msg:
            raise RuntimeError(f"CDP {method}: {msg['error']}")
        return msg.get("result", {})

    def close(self):
        self._closed = True
        try:
            self.sock.close()
        except Exception:
            pass


# ── 无头浏览器会话 ────────────────────────────────────────────────────


class BrowserSession:
    """一个无头 Chromium 实例 + 两条 CDP 通道（页面级/浏览器级）。"""

    def __init__(self, profile_dir: str):
        self.profile_dir = profile_dir
        # 画面帧队列：page_ws 的 pump 线程投进来，ws_endpoint 的 frames_out 消费
        self.frame_q: "queue.Queue" = queue.Queue()
        self.proc = subprocess.Popen([
            CHROMIUM, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--disable-dev-shm-usage", f"--remote-debugging-port={CDP_PORT}",
            "--remote-debugging-address=127.0.0.1",
            f"--user-data-dir={profile_dir}",
            f"--window-size={VIEW_W},{VIEW_H}",
            "--lang=zh-CN", LOGIN_URL,
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.page_ws: WS | None = None
        self.browser_ws: WS | None = None
        self._connect()

    def _wait_cdp(self, timeout: float = 30.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{CDP_PORT}/json/version", timeout=2) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.4)
        raise RuntimeError("Chromium CDP 没起来")

    def _connect(self):
        self._wait_cdp()
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json/version", timeout=5) as r:
            ver = json.loads(r.read().decode())
        self.browser_ws = WS(ver["webSocketDebuggerUrl"])
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json", timeout=5) as r:
            targets = json.loads(r.read().decode())
        page = next(t for t in targets if t.get("type") == "page"
                    and DOMAIN_HINT in (t.get("url") or ""))
        self.page_ws = WS(page["webSocketDebuggerUrl"])
        self.page_ws.on_event(self._on_page_event)
        self.page_ws.call("Page.enable")
        self.page_ws.call("Emulation.setDeviceMetricsOverride", {
            "width": VIEW_W, "height": VIEW_H, "deviceScaleFactor": 1, "mobile": False})

    def _on_page_event(self, msg: dict):
        """pump 线程里跑：只投队列，绝不阻塞（ack 由消费线程补）。"""
        if msg.get("method") == "Page.screencastFrame":
            self.frame_q.put(msg.get("params", {}))

    def start_screencast(self):
        self.page_ws.call("Page.startScreencast", {
            "format": "jpeg", "quality": 60,
            "maxWidth": VIEW_W, "maxHeight": VIEW_H, "everyNthFrame": 1})

    def stop_screencast(self):
        try:
            self.page_ws.call("Page.stopScreencast")
        except Exception:
            pass

    def ack(self, session_id: int):
        try:
            self.page_ws.call("Page.screencastFrameAck", {"sessionId": session_id})
        except Exception:
            pass

    def cookies(self) -> dict[str, dict]:
        res = self.browser_ws.call("Storage.getCookies", {}, timeout=10)
        out = {}
        for c in res.get("cookies", []):
            if DOMAIN_HINT not in (c.get("domain") or ""):
                continue
            name = c.get("name")
            if not name:
                continue
            try:
                exp = int(float(c.get("expires", -1)))
            except (TypeError, ValueError):
                exp = -1
            out[name] = {"value": c.get("value", ""), "expires": exp}
        return out

    def login_email(self) -> str:
        try:
            r = self.page_ws.call("Runtime.evaluate", {
                "expression": (
                    "(function(){try{"
                    "var m=document.querySelector('meta[name=user-email]');"
                    "if(m&&m.content)return m.content;"
                    "var t=document.body?document.body.innerText:'';"
                    "var x=t.match(/[\\w.+-]+@[\\w-]+\\.[\\w.]+/);"
                    "return x?x[0]:'';}catch(e){return '';}})()"
                ), "returnByValue": True}, timeout=8)
            return str((r.get("result") or {}).get("value") or "").strip()
        except Exception:
            return ""

    def dispatch_mouse(self, ev: dict):
        p = {"x": ev["x"], "y": ev["y"]}
        kind = ev["kind"]
        if kind == "move":
            p["type"] = "mouseMoved"
        elif kind == "down":
            # buttons=1 标明左键正按着 —— 缺了这个，一些前端框架不认这次点击
            p.update(type="mousePressed", button="left", clickCount=1, buttons=1)
        elif kind == "up":
            p.update(type="mouseReleased", button="left", clickCount=1, buttons=0)
        elif kind == "wheel":
            p.update(type="mouseWheel", deltaX=ev.get("dx", 0), deltaY=ev.get("dy", 0))
        else:
            return
        self.page_ws.call("Input.dispatchMouseEvent", p, timeout=5)

    _KEYMAP = {"Enter": 13, "Backspace": 8, "Tab": 9, "Escape": 27,
               "Delete": 46, "Home": 36, "End": 35, "PageUp": 33, "PageDown": 34,
               "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40}

    def dispatch_key(self, ev: dict):
        key = ev.get("key", "")
        if len(key) == 1:  # 可打印字符：insertText 最稳（含非 ASCII）
            self.page_ws.call("Input.insertText", {"text": key}, timeout=5)
            return
        code = self._KEYMAP.get(key)
        if code is None:
            return
        for t in ("rawKeyDown", "keyUp"):
            self.page_ws.call("Input.dispatchKeyEvent", {
                "type": t, "key": key, "code": key,
                "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code}, timeout=5)

    def kill(self):
        self.stop_screencast()
        for ws in (self.page_ws, self.browser_ws):
            if ws:
                ws.close()
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


# ── 账号池 API ────────────────────────────────────────────────────────


def _api(path: str, method: str = "GET", payload: dict | None = None) -> dict:
    url = API_BASE.rstrip("/") + path
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Authorization": f"Bearer {API_KEY}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode("utf-8", "replace")
        return json.loads(body) if body.strip() else {}


def list_accounts() -> list[dict]:
    """账号池里的账号列表（按 label 判重用）。拿不到就返回空表。"""
    try:
        r = _api("/admin/accounts")
    except Exception:
        return []
    if isinstance(r, list):
        return r
    for k in ("accounts", "items", "data", "list"):
        v = r.get(k)
        if isinstance(v, list):
            return v
    return []


def pool_count() -> int:
    try:
        r = _api("/admin/accounts")
        if isinstance(r, list):
            return len(r)
        for k in ("accounts", "items", "data", "list"):
            v = r.get(k)
            if isinstance(v, list):
                return len(v)
    except Exception:
        pass
    return -1


def import_account(label: str, cookies: dict[str, dict]) -> dict:
    """把一次登录抓到的 cookie 写进账号池。

    v1.5.0：先按邮箱找同款账号 —— 命中就更新它那份 cookie（走
    /admin/accounts/{id}/cookies，该端点会重置有效期锚点），不新增条目。
    只有真正的新账号才追加。返回结果带 updated 标志。
    """
    payload_cookies = {k: v["value"] for k, v in cookies.items()}
    payload_expires = {k: v["expires"] for k, v in cookies.items() if v["expires"] > 0}

    key = (label or "").strip().lower()
    existing = None
    if key:
        for a in list_accounts():
            if (a.get("label") or "").strip().lower() == key:
                existing = a
                break

    if existing:
        r = _api(f"/admin/accounts/{existing['id']}/cookies", "POST", {
            "cookies": payload_cookies, "expires": payload_expires})
        r = dict(r) if isinstance(r, dict) else {}
        r["updated"] = True
        r["id"] = existing["id"]
        return r

    r = _api("/admin/accounts", "POST", {
        "label": label,
        "cookies": payload_cookies,
        "expires": payload_expires,
    })
    r = dict(r) if isinstance(r, dict) else {}
    r["updated"] = False
    return r


# ── 导号令牌（install.sh --add-account 在宿主机生成）──────────────────
#    文件经 ./runtime 卷共享。宿主机只「加新令牌+清理过期」，本进程只
#    「回写导入计数」——两边都是读-改-原子替换，竞争窗口的最坏结果只是
#    丢一次计数（终端少报一次），不会丢令牌本身。
_active_tokens: set[str] = set()      # 正被某条 ws 占用的令牌


def _load_tokens() -> dict:
    try:
        with open(TOKENS_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def _save_tokens(tokens: dict) -> None:
    directory = os.path.dirname(TOKENS_FILE) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tokens-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(tokens, f)
        os.replace(tmp, TOKENS_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def token_valid(token: str) -> bool:
    """令牌只在它的时间窗口内有效（不因用过一次而废）。"""
    if not token:
        return False
    m = _load_tokens().get(token)
    if not isinstance(m, dict):
        return False
    try:
        return float(m.get("expires", 0)) > time.time()
    except (TypeError, ValueError):
        return False


def record_import(token: str, email: str) -> None:
    """记一次成功导入：计数 +1、记住邮箱，并把窗口再续 15 分钟。

    v1.5.0 起令牌不再「用一次就废」—— 一个窗口里可以连着导多个账号
    （网页上点「再导一个」），连续导入也不会中途过期。
    """
    tokens = _load_tokens()
    m = tokens.get(token)
    if not isinstance(m, dict):
        return
    try:
        m["imports"] = int(m.get("imports", 0) or 0) + 1
    except (TypeError, ValueError):
        m["imports"] = 1
    m["email"] = email
    m["expires"] = time.time() + TOKEN_TTL
    tokens[token] = m
    _save_tokens(tokens)


# ── 网页（无任何密钥，key 由用户输入后仅存 sessionStorage）────────────

PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>导入 muse.ai 账号</title>
<style>
  body{margin:0;font-family:system-ui,sans-serif;background:#1c1c1e;color:#eee;
       display:flex;flex-direction:column;align-items:center;min-height:100vh}
  .bar{width:100%;max-width:__W__px;padding:10px 14px;box-sizing:border-box}
  h1{font-size:16px;margin:8px 0}
  .hint{font-size:13px;color:#9a9aa0;line-height:1.7}
  #keyrow{display:flex;gap:8px;margin:10px 0}
  input{flex:1;padding:9px 12px;border-radius:8px;border:1px solid #3a3a3e;
        background:#2c2c2e;color:#eee;font-size:14px;outline:none}
  button{padding:9px 16px;border-radius:8px;border:0;background:#0a84ff;
         color:#fff;font-size:14px;cursor:pointer}
  button:disabled{background:#3a3a3e;cursor:default}
  #stage{display:none;position:relative;border-radius:10px;overflow:hidden;
         box-shadow:0 8px 40px rgba(0,0,0,.5)}
  #view{display:block;cursor:pointer;background:#000}
  #status{padding:10px 14px;font-size:14px;min-height:20px}
  .ok{color:#30d158}.err{color:#ff453a}
</style></head><body>
<div class="bar">
  <h1>导入 muse.ai 账号 → 视频工作台</h1>
  <div class="hint" id="hints">
    ① 粘贴 API Key（--status 能看到）→ ② 点「打开登录窗口」→
    ③ 在下面的窗口里登录 muse.ai → ④ 看到「导入成功」就好了。
    想加第二个账号，登录成功后点「再导一个」。
  </div>
  <div id="keyrow">
    <input id="key" type="password" placeholder="API Key（形如 m2a_xxxx…）">
    <button id="start" onclick="start()">打开登录窗口</button>
  </div>
  <div id="stage">
    <img id="view" width="__W__" height="__H__" alt="登录窗口加载中…">
  </div>
  <div id="status"></div>
</div>
<script>
const stage=document.getElementById('stage'),view=document.getElementById('view'),
      statusEl=document.getElementById('status'),keyEl=document.getElementById('key');
// v1.4.0：终端 --add-account 生成的链接带 ?token=，跳过填 Key 直接开窗
// v1.5.0：令牌有效期内可以连着导多个账号（导完点「再导一个」）
const urlTok=new URLSearchParams(location.search).get('token')||'';
if(urlTok){
  document.getElementById('keyrow').style.display='none';
  document.getElementById('hints').innerHTML='这是终端生成的导号窗口（15 分钟内有效，可以连着导多个账号）。'+
    '<br>登录窗口正在打开 —— 在里面登录 muse.ai，看到「导入成功」就好了。'+
    '<br>想导下一个账号，点「再导一个账号」，再登录另一个 muse.ai 账号。';
}
keyEl.value=sessionStorage.getItem('mvw_key')||'';
let ws=null,again=false;
function say(t,cls){statusEl.textContent=t;statusEl.className=cls||'';}
function start(){
  const key=keyEl.value.trim();
  if(!urlTok&&!key){say('先填 API Key','err');return;}
  if(!urlTok)sessionStorage.setItem('mvw_key',key);
  document.getElementById('start').disabled=true;
  say('正在启动登录窗口…');
  const q=urlTok?'token='+encodeURIComponent(urlTok):'key='+encodeURIComponent(key);
  ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/ws?'+q);
  ws.onmessage=e=>{
    const m=JSON.parse(e.data);
    if(m.type==='frame'){stage.style.display='block';view.src='data:image/jpeg;base64,'+m.data;}
    else if(m.type==='info'){say(m.text);}
    else if(m.type==='done'){
      say((m.updated?'✓ 这个账号之前导过，已刷新它的会话：':'✓ 导入成功：')+m.label+
          (m.count>=0?'（账号池现有 '+m.count+' 个）':''),'ok');
      const b=document.createElement('button');b.textContent='再导一个账号';
      b.style.marginLeft='10px';
      b.onclick=()=>{b.remove();say('正在重置窗口，换个 muse.ai 账号登录…');
        ws.send(JSON.stringify({kind:'again'}));};
      statusEl.appendChild(b);
    }
    else if(m.type==='error'){say('× '+m.text,'err');document.getElementById('start').disabled=false;}
  };
  ws.onclose=()=>{if(statusEl.className!=='ok'){say('连接断开了，刷新页面重试','err');
    document.getElementById('start').disabled=false;}};
  ws.onerror=()=>say(urlTok?'× 连接失败（链接过期了？回终端重新跑 --add-account 生成一条新的）':'× 连接失败（Key 不对？服务没起来？）','err');
}
if(urlTok)start();
function pos(e){const r=view.getBoundingClientRect();
  return{x:Math.round((e.clientX-r.left)*__W__/r.width),
         y:Math.round((e.clientY-r.top)*__H__/r.height)};}
view.addEventListener('mousemove',e=>{if(ws&&ws.readyState===1){const p=pos(e);
  ws.send(JSON.stringify({kind:'move',...p}));}});
view.addEventListener('mousedown',e=>{const p=pos(e);
  ws.send(JSON.stringify({kind:'down',...p}));});
view.addEventListener('mouseup',e=>{const p=pos(e);
  ws.send(JSON.stringify({kind:'up',...p}));});
view.addEventListener('wheel',e=>{e.preventDefault();const p=pos(e);
  ws.send(JSON.stringify({kind:'wheel',...p,dx:e.deltaX,dy:e.deltaY}));},{passive:false});
document.addEventListener('keydown',e=>{
  if(!ws||ws.readyState!==1||document.activeElement===keyEl)return;
  if(e.key.length===1||['Enter','Backspace','Tab','Escape','Delete','Home','End',
     'PageUp','PageDown','ArrowLeft','ArrowUp','ArrowRight','ArrowDown'].includes(e.key)){
    e.preventDefault();ws.send(JSON.stringify({kind:'key',key:e.key}));}});
</script></body></html>""".replace("__W__", str(VIEW_W)).replace("__H__", str(VIEW_H))


# ── FastAPI 服务 ──────────────────────────────────────────────────────

app = FastAPI()
_busy = asyncio.Lock()


@app.get("/", response_class=HTMLResponse)
async def index():
    return PAGE


@app.get("/healthz")
async def healthz():
    return {"ok": True, "service": "mvw-importer"}


@app.get("/api/token_status")
async def token_status(token: str = "", since: int = 0):
    """终端 install.sh --add-account 的轮询端点（只经回环调用）。

    since = 终端已经报过的导入次数（第一次问传 0）。
    返回的 state：
      pending   链接已生成，还没人打开
      active    浏览器窗口正开着，用户正在里面操作
      done      本次窗口又导进来了一个（imports > since），带 email / imports / count
      expired   窗口超时（15 分钟无人操作）
      unknown   令牌不存在
    """
    if not token:
        return {"state": "unknown"}
    m = _load_tokens().get(token)
    if not isinstance(m, dict):
        return {"state": "unknown"}
    try:
        expires = float(m.get("expires", 0))
    except (TypeError, ValueError):
        return {"state": "unknown"}
    try:
        imports = int(m.get("imports", 0) or 0)
    except (TypeError, ValueError):
        imports = 0
    if imports > since:
        return {"state": "done", "email": m.get("email", ""),
                "imports": imports, "count": pool_count()}
    if expires <= time.time():
        return {"state": "expired"}
    if token in _active_tokens:
        return {"state": "active"}
    return {"state": "pending"}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    key = ws.query_params.get("key", "")
    token = ws.query_params.get("token", "")
    via_token = False
    if key and API_KEY and hmac.compare_digest(key, API_KEY):
        pass  # 主 Key 通道（网页手填 Key 的老方式，长期有效）
    elif token and token_valid(token):
        # ⚠️ 令牌在导入成功前允许刷新重连（不因断开而作废），但同一时刻
        #    只允许一个窗口占用 —— 防止链接被转发后多人同时开。
        if token in _active_tokens:
            await ws.accept()
            await ws.send_json({"type": "error", "text": "这条链接已经在另一个窗口打开了"})
            await ws.close()
            return
        via_token = True
    else:
        await ws.close(code=4401)
        return
    if _busy.locked():
        await ws.accept()
        await ws.send_json({"type": "error",
                            "text": "正有人在用导入窗口，稍等一会再刷新"})
        await ws.close()
        return
    if via_token:
        _active_tokens.add(token)
    await ws.accept()
    async with _busy:
        session: BrowserSession | None = None
        loop = asyncio.get_running_loop()
        try:
            profile = tempfile.mkdtemp(prefix="muse-login-")
            try:
                session = await loop.run_in_executor(None, BrowserSession, profile)
            except Exception as e:
                await ws.send_json({"type": "error", "text": f"浏览器启动失败：{e}"})
                return
            await ws.send_json({"type": "info", "text": "登录窗口就绪，在里面登录 muse.ai"})
            await loop.run_in_executor(None, session.start_screencast)

            stop = asyncio.Event()
            last_active = time.time()
            # 本窗口已经导过的邮箱 —— cookie_watch 每 2 秒轮一次，没有这个集合
            # 就会对着同一个已登录账号反复导入（v1.5.0 修）。点「再导一个」
            # 会换干净 profile 并清空它。
            imported_labels: set[str] = set()

            async def frames_out():
                """画面帧 → 浏览器。帧由 page_ws 的 pump 线程投进 frame_q，
                这里只消费（ack + 转发），不再直接碰 socket —— 多线程抢读
                同一条 socket 就是「画面能动、点击全死」的病根。"""
                while not stop.is_set():
                    try:
                        p = await loop.run_in_executor(
                            None, lambda: session.frame_q.get(True, 1.0))
                    except queue.Empty:
                        p = None
                    except Exception:
                        stop.set()
                        return
                    if p is not None:
                        await loop.run_in_executor(
                            None, session.ack, p.get("sessionId", 0))
                        try:
                            await ws.send_json({"type": "frame", "data": p.get("data", "")})
                        except Exception:
                            stop.set()
                            return
                    if time.time() - last_active > IDLE_TIMEOUT:
                        await ws.send_json({"type": "error", "text": "闲置太久，窗口已回收，刷新重来"})
                        stop.set()
                        return

            async def input_in():
                """浏览器输入事件 → CDP。"""
                nonlocal last_active
                while not stop.is_set():
                    try:
                        raw = await asyncio.wait_for(ws.receive_text(), timeout=1.0)
                    except asyncio.TimeoutError:
                        continue
                    except WebSocketDisconnect:
                        stop.set()
                        return
                    last_active = time.time()
                    try:
                        ev = json.loads(raw)
                    except Exception:
                        continue
                    kind = ev.get("kind")
                    try:
                        if kind == "again":
                            # 重置：换干净 profile 重启，继续同一条 ws
                            await loop.run_in_executor(None, _reset_browser, session)
                            imported_labels.clear()
                        elif kind == "key":
                            await loop.run_in_executor(None, session.dispatch_key, ev)
                        else:
                            await loop.run_in_executor(None, session.dispatch_mouse, ev)
                    except Exception:
                        pass

            async def cookie_watch():
                """盯 session cookie：出现 → 自动抓全量 → 自动注册账号池。"""
                while not stop.is_set():
                    await asyncio.sleep(2.0)
                    try:
                        cookies = await loop.run_in_executor(None, session.cookies)
                        if SESSION_COOKIE not in cookies:
                            continue
                        email = await loop.run_in_executor(None, session.login_email)
                        if not email:
                            continue  # 登录中转态，等页面稳定
                        label = email
                        if label.strip().lower() in imported_labels:
                            continue  # 这个账号本窗口已经导过了
                        res = await loop.run_in_executor(
                            None, import_account, label, cookies)
                        imported_labels.add(label.strip().lower())
                        if via_token:
                            # 一次成功导入 = 一次进度；终端的
                            # /api/token_status?since=N 轮询会依次拿到每个结果
                            await loop.run_in_executor(None, record_import, token, label)
                        await ws.send_json({
                            "type": "done", "label": label, "count": pool_count(),
                            "updated": bool(isinstance(res, dict) and res.get("updated"))})
                    except WebSocketDisconnect:
                        stop.set()
                        return
                    except Exception:
                        pass

            def _reset_browser(sess: BrowserSession):
                sess.kill()
                new_profile = tempfile.mkdtemp(prefix="muse-login-")
                ns = BrowserSession(new_profile)
                sess.__dict__.update(ns.__dict__)
                sess.start_screencast()

            tasks = [asyncio.create_task(t()) for t in
                     (frames_out, input_in, cookie_watch)]
            await stop.wait()
            for t in tasks:
                t.cancel()
        finally:
            if session:
                await asyncio.get_running_loop().run_in_executor(None, session.kill)
            if via_token:
                _active_tokens.discard(token)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=IMPORT_PORT, log_level="warning")
