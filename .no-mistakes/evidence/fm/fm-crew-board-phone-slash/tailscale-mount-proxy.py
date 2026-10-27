# Mimic `tailscale serve --set-path /crew-board`: strip mount prefix, add identity header; "/" is another service that 404s.
import sys, urllib.request, urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
BACK = sys.argv[2]; LOG = open(sys.argv[3], "a")
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path
        if p == "/crew-board" or p.startswith("/crew-board/") or p.startswith("/crew-board?"):
            inner = p[len("/crew-board"):] or "/"
            if inner.startswith("?"): inner = "/" + inner
            req = urllib.request.Request(BACK + inner, headers={"Tailscale-User-Login": "owner@example.com"})
            try: r = urllib.request.urlopen(req); code, body, ct = r.status, r.read(), r.headers["Content-Type"]
            except urllib.error.HTTPError as e: code, body, ct = e.code, e.read(), e.headers["Content-Type"]
        else:
            code, body, ct = 404, b"404 from other service at /", "text/plain"
        LOG.write(f"{p} -> {code}\n"); LOG.flush()
        self.send_response(code); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
