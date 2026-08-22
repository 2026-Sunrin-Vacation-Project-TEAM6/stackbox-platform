#!/bin/sh
set -eu

RETRIES=30
DELAY=2

check() {
  name="$1"
  url="$2"
  echo "==> waiting for ${name} (${url})"
  i=0
  while ! curl -fsS -L -o /dev/null "$url"; do
    i=$((i + 1))
    if [ "$i" -ge "$RETRIES" ]; then
      echo "FAIL: ${name} never became reachable at ${url}"
      exit 1
    fi
    sleep "$DELAY"
  done
  echo "OK: ${name}"
}

check "backend"     "http://backend:8000/health"
check "web_worker"  "http://web_worker:3000/health"
check "code_runner" "http://code_runner:3001/health"
check "frontend"    "http://frontend:3000/"
check "nginx"       "http://nginx:80/"

echo "All services are up. Smoke test passed."
