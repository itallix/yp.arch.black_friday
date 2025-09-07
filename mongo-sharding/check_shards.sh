#!/bin/bash
set -e

declare -A SHARD_PORTS=( [shard1]=27018 [shard2]=27019 )

echo "Checking document count in somedb.helloDoc for both shards..."

for SHARD in "${!SHARD_PORTS[@]}"; do
  PORT=${SHARD_PORTS[$SHARD]}
  COUNT=$(docker compose exec -T $SHARD mongosh --port $PORT --quiet --eval '
    db = db.getSiblingDB("somedb");
    print(db.helloDoc.countDocuments());
  ')
  echo "Shard: $SHARD (port $PORT) | somedb.helloDoc documents: $COUNT"
done
