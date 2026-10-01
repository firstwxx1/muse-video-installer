#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Muse 视频工作台 · 网页一键导号 sidecar（v1.3.0）

干什么用：
    原版导号要在用户自己的电脑上装 Python、跑脚本、手填服务器地址和 Key。
    这个 sidecar 把「登录 muse.ai」整个搬进网页 —— 它在本容器里起一个无头
    Chromium，把页面画面实时投屏到用户的浏览器（CDP screencast），用户的
    鼠标键盘操作转发回去。用户在里面登录 muse.ai，session cookie 一出现就
    自动抓下来、自动注册进 muse2api 账号池。用户全程只需要一个浏览器。

安全模型：
    · 网页本身不含任何密钥（连 HTML 都是公开无害的）
    · WebSocket 连接必须带 ?key=<MUSE2API_KEY>，与 compose 注入的环境变量比对
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
import shutil
import socket
import struct
import subprocess
import tempfile
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
CHROMIUM = os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium")
CDP_PORT = 19999  # 容器内回环端口，不发布
LOGIN_URL = "https://muse.ai/login"
DOMAIN_HINT = "muse.ai"
SESSION_COOKIE = "hatch_sess"     # 登录成功后必然出现的会话 cookie
VIEW_W, VIEW_H = 1280, 800
IDLE_TIMEOUT = 600                # 无操作 10 分钟自动回收浏览器

# ── 极简 WebSocket 客户端（RFC6455 文本帧，stdlib，供 CDP 用）────────
#    与上游 tools/get_muse_cookie.py 里的 WS 同族：容器里没有 websocket-client，
#    自己实现一个 100 行以内的够用品。


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
        self.sock.settimeout(timeout)

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
        self._id += 1
        mid = self._id
        self._frame(json.dumps({"id": mid, "method": method,
                                "params": params or {}}).encode())
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.recv_msg()
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"CDP {method}: {msg['error']}")
                return msg.get("result", {})
        raise TimeoutError(f"CDP {method} 超时")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# ── 无头浏览器会话 ────────────────────────────────────────────────────


class BrowserSession:
    """一个无头 Chromium 实例 + 两条 CDP 通道（页面级/浏览器级）。"""

    def __init__(self, profile_dir: str):
        self.profile_dir = profile_dir
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
        self.page_ws.call("Page.enable")
        self.page_ws.call("Emulation.setDeviceMetricsOverride", {
            "width": VIEW_W, "height": VIEW_H, "deviceScaleFactor": 1, "mobile": False})

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
            p.update(type="mousePressed", button="left", clickCount=1)
        elif kind == "up":
            p.update(type="mouseReleased", button="left", clickCount=1)
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
    return _api("/admin/accounts", "POST", {
        "label": label,
        "cookies": {k: v["value"] for k, v in cookies.items()},
        "expires": {k: v["expires"] for k, v in cookies.items() if v["expires"] > 0},
    })


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
keyEl.value=sessionStorage.getItem('mvw_key')||'';
let ws=null,again=false;
function say(t,cls){statusEl.textContent=t;statusEl.className=cls||'';}
function start(){
  const key=keyEl.value.trim();
  if(!key){say('先填 API Key','err');return;}
  sessionStorage.setItem('mvw_key',key);
  document.getElementById('start').disabled=true;
  say('正在启动登录窗口…');
  ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/ws?key='+encodeURIComponent(key));
  ws.onmessage=e=>{
    const m=JSON.parse(e.data);
    if(m.type==='frame'){stage.style.display='block';view.src='data:image/jpeg;base64,'+m.data;}
    else if(m.type==='info'){say(m.text);}
    else if(m.type==='done'){
      say('✓ 导入成功：'+m.label+(m.count>=0?'（账号池现有 '+m.count+' 个）':''),'ok');
      const b=document.createElement('button');b.textContent='再导一个账号';
      b.style.marginLeft='10px';b.onclick=()=>{b.remove();say('正在重置窗口…');ws.send(JSON.stringify({kind:'again'}));};
      statusEl.appendChild(b);
    }
    else if(m.type==='error'){say('× '+m.text,'err');document.getElementById('start').disabled=false;}
  };
  ws.onclose=()=>{if(statusEl.className!=='ok'){say('连接断开了，刷新页面重试','err');
    document.getElementById('start').disabled=false;}};
  ws.onerror=()=>say('× 连接失败（Key 不对？服务没起来？）','err');
}
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


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    key = ws.query_params.get("key", "")
    if not API_KEY or not hmac.compare_digest(key, API_KEY):
        await ws.close(code=4401)
        return
    if _busy.locked():
        await ws.accept()
        await ws.send_json({"type": "error",
                            "text": "正有人在用导入窗口，稍等一会再刷新"})
        await ws.close()
        return
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

            async def frames_out():
                """CDP 画面帧 → 浏览器（阻塞 socket 放线程里跑）。"""
                while not stop.is_set():
                    try:
                        msg = await loop.run_in_executor(None, session.page_ws.recv_msg)
                    except Exception:
                        stop.set()
                        return
                    if msg.get("method") == "Page.screencastFrame":
                        p = msg.get("params", {})
                        session.ack(p.get("sessionId", 0))
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
                        await loop.run_in_executor(None, import_account, label, cookies)
                        await ws.send_json({
                            "type": "done", "label": label, "count": pool_count()})
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


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=IMPORT_PORT, log_level="warning")
