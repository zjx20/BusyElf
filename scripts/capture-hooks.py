#!/usr/bin/env python3
"""
捕获 Claude Code 真实 hook 事件(调试用,见 AGENTS.md「调试技巧:捕获真实 hook 事件」)。

把每个收到的 POST body 带时间戳全量追加进一个 JSONL,并**立即回 200 空体**
(行为同 BusyElf,绝不干扰 Claude Code 的 hook 流程)。用来核对"某场景下 Claude Code
到底发了哪些 hook、字段长啥样"——比读日志/给 BusyElf 加日志重建强,且免重建。

用法:
    # 独立后台起(不占 Claude 后台任务槽,这样 background_tasks 里只剩你要观测的目标):
    nohup python3 scripts/capture-hooks.py > /tmp/busyelf-capture.log 2>&1 &

    # 然后临时给关心的事件追加一条 capture hook(只加,绝不动 BusyElf 那条),指向本服务:
    #   {"type":"http","url":"http://127.0.0.1:17899/capture","timeout":5}
    # settings.json 改动会被热加载,当前会话即生效;用完务必从备份还原。

    # 读取(Stop 在你结束本轮那刻才发,跨 turn 读):
    cat "$(python3 scripts/capture-hooks.py --logpath)"   # 打印日志路径
    # 或用 jq 过滤某事件的 background_tasks 等字段。

配置(均可选):
    端口:  argv[1] 或 $BUSYELF_CAPTURE_PORT   (默认 17899)
    日志:  argv[2] 或 $BUSYELF_CAPTURE_LOG    (默认 $TMPDIR/busyelf-hook-capture.jsonl)
    --logpath  只打印将使用的日志路径后退出(配合 cat/jq 用)。
"""
import json
import os
import sys
import datetime
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 17899
DEFAULT_LOG = os.path.join(tempfile.gettempdir(), "busyelf-hook-capture.jsonl")


def log_path() -> str:
    if len(sys.argv) > 2 and not sys.argv[2].startswith("-"):
        return sys.argv[2]
    return os.environ.get("BUSYELF_CAPTURE_LOG", DEFAULT_LOG)


def port() -> int:
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        return int(sys.argv[1])
    return int(os.environ.get("BUSYELF_CAPTURE_PORT", DEFAULT_PORT))


LOG = log_path()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        text = body.decode("utf-8", "replace")
        event = None
        try:
            event = json.loads(text).get("hook_event_name")
        except Exception:
            pass
        rec = {"ts": datetime.datetime.now().isoformat(), "event": event, "raw": text}
        try:
            with open(LOG, "a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except Exception:
            pass
        self.send_response(200)        # 始终 200 空体:对 Claude Code 等同无操作,绝不干扰其流程
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):                  # 健康检查
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):      # 静音默认访问日志
        pass


if __name__ == "__main__":
    if "--logpath" in sys.argv:
        print(LOG)
        sys.exit(0)
    p = port()
    print(f"capture-hooks: 监听 127.0.0.1:{p} → 落盘 {LOG}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", p), Handler).serve_forever()
