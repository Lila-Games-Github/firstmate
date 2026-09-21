#!/usr/bin/env python3
"""Local-only Jev-shaped HTTP fixture used by fm-jev.test.sh."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


port_file, log_file = sys.argv[1:3]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        request = json.loads(body)
        with open(log_file, "a", encoding="utf-8") as log:
            log.write(json.dumps(request, separators=(",", ":")) + "\n")

        answers = {}
        state_text = json.dumps(request.get("state", {}), separators=(",", ":"))
        for key, question in request["questions"].items():
            qtype = question["type"]
            if qtype == "noul":
                if key.startswith("criterion_") and "FORCE_UNMET" in state_text:
                    probability = 0.05
                elif key.endswith("__credential") and "FORCE_CREDENTIAL_FLAG" in state_text:
                    probability = 0.95
                elif key.endswith("__persistence"):
                    probability = 0.05
                elif key.endswith("__tests_weakened"):
                    probability = 0.05
                elif key.endswith("__debug_output"):
                    probability = 0.05
                elif key.endswith("__credential"):
                    probability = 0.05
                else:
                    probability = 0.95
                answers[key] = {"type": "noul", "noul": probability}
            elif qtype == "choice":
                options = list(question["criteria"].keys())
                if key == "attention":
                    choice = "actionable"
                elif key == "review_kind":
                    choice = "ruling"
                elif "settled" in options:
                    choice = "settled"
                else:
                    choice = options[0]
                remaining = (1.0 - 0.9) / (len(options) - 1)
                probabilities = {option: remaining for option in options}
                probabilities[choice] = 0.9
                answers[key] = {
                    "type": "choice",
                    "choice": choice,
                    "confidence": 0.9,
                    "probabilities": probabilities,
                }
            else:
                levels = len(question["criteria"])
                probabilities = [0.0] * levels
                probabilities[-1] = 1.0
                answers[key] = {
                    "type": "score",
                    "score": levels - 1,
                    "confidence": 1.0,
                    "probabilities": probabilities,
                }

        response = {
            "model": "jev-1.13.0",
            "answers": answers,
            "usage": {"input_tokens": max(1, len(body) // 4), "output_tokens": 0},
        }
        encoded = json.dumps(response, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format, *_args):
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as output:
    output.write(str(server.server_port))
server.serve_forever()
