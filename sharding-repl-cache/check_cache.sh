#!/bin/bash

URL="http://localhost:8080/helloDoc/users"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

for i in 1 2 3; do
  echo -e "${YELLOW}Request #$i:${NC}"
  read -r STATUS TIME < <(curl -s -o /dev/null -w "%{http_code} %{time_total}" "$URL")
  echo -e "${GREEN}Status: $STATUS | Time: ${TIME}s${NC}"
done
echo -e "${YELLOW}Note: The first request may take longer due to cold cache.${NC}"
