#!/bin/bash
set -e

REPLICAS=(shard1a shard1b shard1c shard2a shard2b shard2c)

echo "Checking document count in somedb.helloDoc for all shard replicas..."

for REPLICA in "${REPLICAS[@]}"; do
  COUNT=$(docker compose exec -T $REPLICA mongosh --port 27017 --quiet --eval '
    db = db.getSiblingDB("somedb");
    print(db.helloDoc.countDocuments());
  ')
  echo "Replica: $REPLICA | somedb.helloDoc documents: $COUNT"
done
