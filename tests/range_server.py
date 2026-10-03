"""Static file server with HTTP Range support for the snapshot tests.

Failure modes for .tar.gz requests, set through the environment:
  DROP_AFTER=N DROP_TIMES=K  cut the connection after N bytes, the first K times
  STALL_AFTER=N              send N bytes, then stall (once), to exercise timeouts
  IGNORE_RANGE=1             answer every request with 200 and the full body
  SLOW=N                     send at most N bytes per second
"""
import os
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

DROP_AFTER = int(os.environ.get("DROP_AFTER", "0"))
DROP_TIMES = int(os.environ.get("DROP_TIMES", "0"))
STALL_AFTER = int(os.environ.get("STALL_AFTER", "0"))
IGNORE_RANGE = os.environ.get("IGNORE_RANGE") == "1"
SLOW = int(os.environ.get("SLOW", "0"))
served = {}
stalled = set()


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.translate_path(self.path)
        if not (os.path.isfile(path) and path.endswith(".tar.gz")):
            return super().do_GET()
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        partial = bool(rng) and not IGNORE_RANGE
        if partial:
            a, _, b = rng.split("=", 1)[1].partition("-")
            start = int(a)
            end = min(int(b), size - 1) if b else size - 1
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
        n = served.get(path, 0)
        served[path] = n + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Length", str(end - start + 1))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(end - start + 1)
        if n < DROP_TIMES:
            data = data[:DROP_AFTER]
            self.close_connection = True
        try:
            if STALL_AFTER and path not in stalled:
                stalled.add(path)
                self.wfile.write(data[:STALL_AFTER])
                self.wfile.flush()
                time.sleep(3600)
                return
            if SLOW:
                for i in range(0, len(data), SLOW):
                    self.wfile.write(data[i:i + SLOW])
                    self.wfile.flush()
                    time.sleep(1)
                return
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


os.chdir(sys.argv[1])
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
