#!/bin/sh
# Test script executed inside krunvm VM via virtiofs mount

echo "=== virtiofs ==="
LINES=$(wc -l < /workspace/nginx-gateway.conf)
echo "nginx-gateway.conf lines: $LINES"
cat /workspace/nginx-gateway.conf | head -2
echo "virtiofs: OK"

echo "=== gateway via nc ==="
{
  printf "GET /health HTTP/1.0\r\n"
  printf "Host: localhost\r\n"
  printf "\r\n"
} | nc -w 5 localhost 4100
echo "---"

echo "=== mcp via nc ==="
{
  printf "GET /mcp HTTP/1.0\r\n"
  printf "Host: localhost\r\n"
  printf "\r\n"
} | nc -w 5 localhost 4100
echo "---"

echo "=== egress proxy via nc ==="
{
  printf "GET /health HTTP/1.0\r\n"
  printf "Host: localhost\r\n"
  printf "\r\n"
} | nc -w 5 localhost 3128
echo "---"

echo "=== external TCP ==="
nc -w 5 -z 1.1.1.1 53 && echo "DNS_PORT_OPEN" || echo "DNS_PORT_BLOCKED"
nc -w 5 -z 142.251.41.174 80 && echo "GOOGLE_HTTP_OPEN" || echo "GOOGLE_HTTP_BLOCKED"

echo "=== done ==="
