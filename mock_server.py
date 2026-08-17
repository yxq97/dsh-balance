#!/usr/bin/env python3
"""Mock 第三方中转服务器：从 JSON 文件读取余额值，支持 DeepSeek 风格和 OpenAI 风格"""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

DS_FILE = "/tmp/mock_deepseek.json"
OA_FILE = "/tmp/mock_openai.json"

DEFAULT_DS = {"total": "12.34", "topped": "10.00", "granted": "2.34"}
DEFAULT_OA = {"total_available": 56.78, "total_granted": 100.0, "total_used": 43.22}


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/user/balance":
            v = load(DS_FILE, DEFAULT_DS)
            body = json.dumps({
                "is_available": True,
                "balance_infos": [{
                    "currency": "CNY",
                    "total_balance": str(v["total"]),
                    "topped_up_balance": str(v["topped"]),
                    "granted_balance": str(v["granted"]),
                }],
            }).encode()
            self.send_response(200)
        elif path == "/v1/dashboard/billing/credit_grants":
            v = load(OA_FILE, DEFAULT_OA)
            body = json.dumps({
                "total_granted": v["total_granted"],
                "total_used": v["total_used"],
                "total_available": v["total_available"],
                "grants": {"data": []},
            }).encode()
            self.send_response(200)
        else:
            self.send_response(404)
            body = b"not found"
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8899), Handler).serve_forever()
