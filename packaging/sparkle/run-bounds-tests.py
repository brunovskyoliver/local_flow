"""Loopback-only transport fixtures; invokes the actual patched downloader tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import threading
import time

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/deadline':
            time.sleep(35)
            return
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/exact')
            self.end_headers()
            return
        if self.path == '/stall':
            time.sleep(6)
            return
        length = 1048577 if self.path == '/oversize' else 1048576
        self.send_response(200)
        # Omit length to exercise bounds against streamed/chunked unknown lengths.
        self.end_headers()
        try:
            self.wfile.write(b'x' * length)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    environment = dict(os.environ, BOUNDS_TEST_URL=f'http://127.0.0.1:{server.server_port}')
    subprocess.run(['build/Sparkle/bounds-tests'], env=environment, check=True)
finally:
    server.shutdown()
    server.server_close()
