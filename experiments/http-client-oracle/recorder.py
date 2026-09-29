#!/usr/bin/env python3
"""오라클 기록 서버. 127.0.0.1 임시 포트에서 HTTP 프록시 요청 줄을 그대로 기록한다.

사용법: recorder.py <포트 파일> <출력 JSON> [메타데이터 key=value ...]

러너가 `/__oracle__/begin?case=<id>` 로 case 를 알리면 뒤따르는 요청을 그 case 에 묶는다.
`/__oracle__/finish` 를 받으면 기록을 쓰고 스스로 종료한다. 경로는 디코드하지 않는다 — 퍼센트 인코딩이
바로 검증 대상이다.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

STATE = {"case": None, "records": []}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _drain_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def _respond(self, body=b"{}"):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self):
        self._drain_body()
        split = urlsplit(self.path)
        if split.path.startswith("/__oracle__/"):
            self._control(split)
            return
        STATE["records"].append({
            "case": STATE["case"],
            "method": self.command,
            "host": split.netloc or self.headers.get("Host", ""),
            "path": split.path,
            "target": self.path,
        })
        self._respond()

    def _control(self, split):
        if split.path == "/__oracle__/begin":
            STATE["case"] = parse_qs(split.query).get("case", [None])[0]
            self._respond()
        elif split.path == "/__oracle__/finish":
            self._respond()
            write_and_stop(self.server)
        else:
            self.send_error(404, "unknown oracle control path")

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _handle


def write_and_stop(server):
    output = sys.argv[2]
    metadata = dict(item.split("=", 1) for item in sys.argv[3:])
    with open(output, "w", encoding="utf-8") as handle:
        json.dump({"metadata": metadata, "records": STATE["records"]}, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
    threading.Thread(target=server.shutdown, daemon=True).start()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
