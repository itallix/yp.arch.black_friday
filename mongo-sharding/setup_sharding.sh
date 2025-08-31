#!/bin/bash
set -e

docker compose exec config_srv mongosh --eval 'rs.initiate({_id: "config_server", configsvr: true, members: [{ _id: 0, host: "config_srv:27017" }]})'

docker compose exec shard1 mongosh --port 27018 --eval 'rs.initiate({_id: "shard1", members: [{_id: 0, host: "shard1:27018"}]})'

docker compose exec shard2 mongosh --port 27019 --eval 'rs.initiate({_id: "shard2", members: [{_id: 0, host: "shard2:27019"}]})'

# docker compose restart mongos_router

docker compose exec -T mongos_router mongosh --port 27020 <<EOF
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");
EOF

docker compose exec -T mongos_router mongosh --port 27020 <<EOF
use somedb;
db.createCollection("helloDoc");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name": "hashed" });
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i});
EOF

echo "Sharding setup completed."
