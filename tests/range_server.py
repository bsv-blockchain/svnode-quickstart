"""Static file server with HTTP Range support for the snapshot tests.

A request whose path ends in .tar.gz is cut off after DROP_AFTER bytes the
first DROP_TIMES times it is fetched, to simulate a connection dropping
mid-download.
"""
import os, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

DROP_AFTER = int(os.environ.get("DROP_AFTER", "0"))
DROP_TIMES = int(os.environ.get("DROP_TIMES", "0"))
served = {}

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.translate_path(self.path)
        rng = self.headers.get("Range")
        if not os.path.isfile(path) or not rng:
            if os.path.isfile(path) and path.endswith(".tar.gz"):
                return self._send(path, 0)
            return super().do_GET()
        start = int(rng.split("=")[1].split("-")[0])
        return self._send(path, start)

    def _send(self, path, start):
        size = os.path.getsize(path)
        n = served.get(path, 0); served[path] = n + 1
        drop = path.endswith(".tar.gz") and n < DROP_TIMES
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(size - start))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read()
        if drop:
            self.wfile.write(data[:DROP_AFTER])
            self.wfile.flush()
            self.close_connection = True
            return
        self.wfile.write(data)

os.chdir(sys.argv[1])
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
