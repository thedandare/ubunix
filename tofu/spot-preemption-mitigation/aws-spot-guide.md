# AWS Amazon EC2 Spot — Implementation Guide

AWS EC2 Spot Instances allow you to leverage spare EC2 capacity at up to **90% discount** vs On-Demand. The trade-off: AWS can reclaim the instance with a **2-minute warning** when capacity is needed.

> **Docs oficiais:**
> - [Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
> - [Spot Instance interruption notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html)
> - [Prepare for Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/prepare-for-interruptions.html)
> - [Burstable performance instances — CPU credits](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html)

---

## Interruption Mechanics

| Aspect | Detail |
|---|---|
| **Warning time** | 2 minutes (best-effort — can be less in extreme cases) |
| **Notice location** | Instance Metadata Service v2 (IMDSv2) + Amazon EventBridge |
| **Polling recommendation** | Every 5 seconds (AWS official recommendation) |
| **Interruption behaviors** | `terminate` (default), `stop`, or `hibernate` |
| **Hibernation caveat** | No 2-minute warning — hibernation begins immediately |

### Interruption reasons

- Capacity reclaim (most common) — AWS needs the hardware back
- Spot price exceeds your maximum price (if using `spot-max-price`)
- Constraint violation (launch group / AZ group can no longer be met)
- Host maintenance or hardware decommission

---

## Detection Methods

### Method 1: IMDSv2 (from inside the instance) — Recommended

The `spot/instance-action` endpoint returns HTTP 200 with a JSON payload when interruption is pending, or HTTP 404 when no interruption is scheduled.

```bash
# Fetch IMDSv2 token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Check for pending interruption
curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/spot/instance-action
```

Response when termination is scheduled:

```json
{"action": "terminate", "time": "2026-07-07T03:00:00Z"}
```

Response when no interruption: HTTP 404.

> **Legacy endpoint:** `spot/termination-time` returns a plain-text timestamp. AWS recommends using `instance-action` instead.

### Method 2: Amazon EventBridge (from outside the instance)

AWS emits an `EC2 Spot Instance Interruption Warning` event 2 minutes before interruption. Can be routed to Lambda, SNS, SQS for external orchestration.

```json
{
  "detail-type": "EC2 Spot Instance Interruption Warning",
  "source": "aws.ec2",
  "detail": {
    "instance-id": "i-1234567890abcdef0",
    "instance-action": "terminate"
  }
}
```

### Method 3: Rebalance Recommendation (proactive)

AWS emits a **rebalance recommendation** signal when the instance is at **elevated risk** of interruption — before the 2-minute notice. Available via IMDSv2:

```bash
curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/events/recommendations/rebalance
```

This gives you a head start to proactively replace the instance before the hard 2-minute deadline.

---

## Implementation: spot-termination-handler.sh

This repo includes a production-ready handler script: [`spot-termination-handler.sh`](spot-termination-handler.sh).

### What it does

1. Polls `spot/instance-action` via IMDSv2 every 5 seconds
2. On HTTP 200 (interruption detected), executes built-in cleanup:
   - **Drain MicroK8s nodes** — `kubectl cordon` + `kubectl drain`
   - **Stop Incus containers** — `incus stop --timeout 60`
   - **Unmount remote filesystems** — NFS, Lustre, FSx
3. Runs custom hooks from `/etc/spot-termination-hooks.d/*.sh` (alphabetical order, each with timeout)
4. Triggers graceful shutdown

### Installation

```bash
# Copy script and service
cp spot-termination-handler.sh /usr/local/bin/
chmod +x /usr/local/bin/spot-termination-handler.sh
cp spot-termination-handler.service /etc/systemd/system/

# Create hooks directory
mkdir -p /etc/spot-termination-hooks.d

# Copy desired hooks from hooks.example/
cp hooks.example/10-drain-k8s.sh /etc/spot-termination-hooks.d/
cp hooks.example/20-stop-incus.sh /etc/spot-termination-hooks.d/
chmod +x /etc/spot-termination-hooks.d/*.sh

# Enable and start
systemctl daemon-reload
systemctl enable --now spot-termination-handler
```

### Configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `POLL_INTERVAL` | `5` | Seconds between IMDSv2 checks |
| `IMDS_TOKEN_TTL` | `21600` | IMDSv2 token TTL in seconds (6h) |
| `HOOK_TIMEOUT` | `30` | Max seconds per hook script |
| `SHUTDOWN_HOOK_DIR` | `/etc/spot-termination-hooks.d` | Directory for custom hooks |

### Custom hooks

Hooks receive two arguments: `action` (terminate/stop/hibernate) and `termination_time` (ISO 8601 UTC).

```bash
#!/usr/bin/env bash
# /etc/spot-termination-hooks.d/50-my-app.sh
ACTION="$1"
TIME="$2"

# Save state to S3
aws s3 cp /var/lib/myapp/state s3://my-bucket/state-$(hostname)/

# Drain from service discovery
curl -X POST http://consul:8500/v1/agent/service/deregister/my-service
```

### Example hooks included

| Hook | Description |
|---|---|
| `10-drain-k8s.sh` | Cordon + drain all MicroK8s nodes |
| `20-stop-incus.sh` | Stop all Incus containers gracefully |
| `30-notify-tailscale.sh` | Disconnect from Tailscale network |

### Testing

```bash
./test-spot-handler.sh
```

Validates: syntax, JSON parsing (terminate/stop/hibernate), hook execution, hook failure resilience, hook timeout enforcement, built-in functions without dependencies, systemd unit file, example hooks.

---

## Allocation Strategies

### Spot Fleet / Auto Scaling Group strategies

| Strategy | Description | When to use |
|---|---|---|
| `capacity-optimized` | Provisions from pools with most available capacity | **Recommended** — minimizes interruptions |
| `capacity-optimized-prioritized` | Capacity-optimized but respects priority order | Mixed Spot + On-Demand fleets |
| `price-capacity-optimized` | Balances price + capacity availability | Cost-sensitive workloads |
| `lowest-price` | Cheapest pools regardless of capacity | Not recommended — higher interruption risk |
| `diversified` | Spreads across all pools | Maximum diversification |

### Spot Placement Score

Use `GetSpotPlacementScores` API to identify the best AZ/instance type combinations before launching. Scores range from 1 (low availability) to 10 (high availability).

---

## Best Practices

1. **Use `capacity-optimized` allocation** — reduces baseline interruption frequency by targeting pools with the most spare capacity.
2. **Diversify instance types** — specify multiple instance families/sizes in your Spot Fleet or ASG to maximize pool options.
3. **Multi-AZ** — spread across at least 2-3 Availability Zones to reduce blast radius.
4. **On-Demand fallback** — configure ASG with `Spot` + `On-Demand` base capacity (e.g., 70% Spot / 30% On-Demand).
5. **Checkpoint to S3** — save job state periodically so replacement instances can resume.
6. **Use SQS for task queues** — unacknowledged messages return to the queue automatically when a Spot worker dies.
7. **Karpenter for Kubernetes** — auto-provisions replacement nodes with Spot preferences and consolidation.
8. **Monitor with CloudWatch** — track `CPUCreditBalance` on burstable instances (T3/T3a/T4g) to detect throttling before it cascades. Use [`check_cpu_credits.sh`](../util/check_cpu_credits.sh) for a quick audit.
9. **Set rebalance recommendation alerts** — gives you a proactive heads-up before the 2-minute notice.
10. **Test with On-Demand first** — terminate an On-Demand instance manually to validate your graceful shutdown logic.

---

## Spot Instance Lifecycle

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Running (Spot) │────▶│ Rebalance Signal │────▶│ 2-min Warning   │
│                 │     │ (elevated risk)  │     │ (IMDSv2 + EB)   │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                                          ┌───────────────┼───────────────┐
                                          ▼               ▼               ▼
                                   ┌──────────┐   ┌──────────┐   ┌──────────┐
                                   │ Terminate│   │   Stop   │   │Hibernate │
                                   │ (default)│   │(save disk)│   │(save RAM)│
                                   └──────────┘   └──────────┘   └──────────┘
```

- **Terminate**: Instance and EBS volumes are deleted. Data is lost.
- **Stop**: EBS volumes persist. Instance can be restarted (credits reset after 7 days for T3/T3a/T4g).
- **Hibernate**: RAM state saved to EBS. Instance resumes from where it left off. No 2-minute warning.

---

## Burstable Instances (T2/T3/T3a/T4g) on Spot

Spot Instances are often burstable (e.g., `t3.medium`). Key considerations:

- **CPU credits** accumulate when idle, spent when bursting above baseline
- When credits hit zero: CPU is **throttled** to baseline (e.g., 20% for t3.medium = 0.4 vCPU)
- **T3/T3a/T4g default to `unlimited` mode** — instead of throttling, you pay surplus credits (~$0.05/vCPU-hour)
- Spot interruptions bypass all Auto Scaling protections (lifecycle hooks, scale-in protection, suspended processes)
- Credits persist for 7 days when stopped (T3/T3a/T4g); T2 loses all credits immediately

Monitor with CloudWatch metrics: `CPUCreditBalance`, `CPUCreditUsage`, `CPUSurplusCreditBalance`, `CPUSurplusCreditsCharged`.

> See [`check_cpu_credits.sh`](../util/check_cpu_credits.sh) for a script that audits credit balance across all burstable instances.

---

## Terraform Integration

For Spot Fleet / ASG configuration in Terraform:

```hcl
resource "aws_launch_template" "spot" {
  image_id      = var.ami_id
  instance_type = "t3.medium"

  instance_market_options {
    market_type  = "spot"
    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
      max_price                      = 0.05
    }
  }

  user_data = base64encode(templatefile("user_data.nix.tftpl", {
    # ... your variables
  }))
}

resource "aws_spot_fleet_request" "fleet" {
  iam_fleet_role      = aws_iam_role.fleet.arn
  spot_price          = "0.05"
  target_capacity     = 5
  allocation_strategy = "capacity-optimized"

  launch_template_config {
    launch_template_specification {
      launch_template_id = aws_launch_template.spot.id
      version            = "$Latest"
    }
  }
}
```
