# ADR 002: Redpanda vs Apache Kafka

## Status
Accepted

## Context
We need a durable message queue between the hub gateway and destination routers to decouple ingestion from delivery. This provides buffering during destination outages and enables independent scaling of consumers.

## Options Considered
1. **Apache Kafka** - Industry standard, large ecosystem, requires ZooKeeper (or KRaft)
2. **Redpanda** - Kafka API-compatible, single binary, no JVM dependency
3. **NATS JetStream** - Lightweight, different API

## Decision
Use Redpanda for the hub message queue.

## Rationale
- **Operational simplicity**: Single Go binary, no JVM tuning, no ZooKeeper
- **Kafka API compatibility**: All OTel Kafka exporters/receivers work unmodified
- **Lower resource footprint**: Significant for a 3-broker cluster on LKE
- **Built-in monitoring**: Admin API and rpk CLI for operations
- **Performance**: Comparable or better throughput for our scale (< 100k msg/sec)

## Consequences
- **Positive**: Simpler operations, fewer components to manage
- **Positive**: Lower memory/CPU requirements than Kafka + ZooKeeper
- **Positive**: Same Kafka protocol means easy migration if needed
- **Negative**: Smaller community than Kafka
- **Negative**: Some advanced Kafka features may lag
