#!/bin/bash
set -e

docker compose exec -T config1 mongosh <<EOF
rs.initiate({_id: "config_server", configsvr: true, members: [{ _id: 0, host: "config1:27017" }]})
EOF

docker compose exec -T config2 mongosh <<EOF
rs.initiate({_id: "config_server", configsvr: true, members: [{ _id: 0, host: "config2:27017" }]})
EOF

docker compose exec -T config3 mongosh <<EOF
rs.initiate({_id: "config_server", configsvr: true, members: [{ _id: 0, host: "config3:27017" }]})
EOF

docker compose exec -T shard1a mongosh <<EOF 
rs.initiate({_id: "shard1", 
    members: [
        {_id: 0, host: "shard1a:27017"}, 
        {_id: 1, host: "shard1b:27017"}, 
        {_id: 2, host: "shard1c:27017"}
    ]
})
EOF

docker compose exec -T shard2a mongosh <<EOF
rs.initiate({_id: "shard2", 
    members: [
        {_id: 0, host: "shard2a:27017"}, 
        {_id: 1, host: "shard2b:27017"}, 
        {_id: 2, host: "shard2c:27017"}
    ]
})
EOF

docker compose exec -T mongos_router mongosh <<EOF
    sh.addShard("shard1/shard1a:27017,shard1b:27017,shard1c:27017");
    sh.addShard("shard2/shard2a:27017,shard2b:27017,shard2c:27017");
    use somedb;
    db.createCollection("helloDoc");
    sh.enableSharding("somedb");
    sh.shardCollection("somedb.helloDoc", { "name": "hashed" });
    for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i});
EOF

docker compose exec -T redis1 redis-cli <<EOF
    cluster meet 173.17.0.2 6379
    cluster meet 173.17.0.3 6379
    cluster addslots $(seq 0 8191)
EOF

docker compose exec -T redis2 redis-cli <<EOF
    cluster addslots $(seq 8192 16383)
EOF

echo "Sharding setup with replication and caching completed."
