#!/usr/bin/env bash
#
# 합성 클라이언트의 요청을 로컬 기록 서버로 실행해 recorded.json 을 다시 만든다.
# Alamofire·Moya 를 SwiftPM 으로 받으므로 네트워크가 필요하다. 기본 CI 에서는 돌지 않고,
# cartograph 테스트(HTTPClientOracleTests)는 커밋된 recorded.json 과 소스만 읽는다.
set -euo pipefail
cd "$(dirname "$0")"

swift build --product OracleRunner
runner="$(swift build --show-bin-path)/OracleRunner"
workdir="$(mktemp -d)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid"; fi
    rm -rf "$workdir"
}
trap cleanup EXIT

resolved() { python3 -c 'import json,sys; pins={p["identity"]:p["state"].get("version") for p in json.load(open("Package.resolved"))["pins"]}; print(pins.get(sys.argv[1], ""))' "$1"; }

python3 recorder.py "$workdir/port" recorded.json \
    "os=macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
    "swift=$(swift --version 2>&1 | head -1)" \
    "alamofire=$(resolved alamofire)" "moya=$(resolved moya)" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$workdir/port" ]] && break; sleep 0.1; done
[[ -s "$workdir/port" ]] || { echo "recorder did not start" >&2; exit 2; }

"$runner" "$(cat "$workdir/port")"
wait "$server_pid"
server_pid=""
echo "recorded $(python3 -c 'import json; print(len(json.load(open("recorded.json"))["records"]))') request(s) into recorded.json"
