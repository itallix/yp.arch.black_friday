# Mondo setup with 2 shards

This project provides a Docker Compose setup for a sharded MongoDB cluster with two shards, a config server, and a sample API.

## Usage

1. Build and Start the Cluster

```bash
docker compose up --build
```

2. Initialize Sharding with Replication

```bash
./setup.sh
```

3. Check Shard Status

```bash
./check_shard.sh
```

4. Check the API

```
curl localhost:8080 | jq
```
