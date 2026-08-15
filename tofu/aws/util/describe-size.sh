# 1. Get a Clean List of Running Instance IDs
aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].{ID:InstanceId, Name:Tags[?Key=='Name'].Value | [0]}" \
    --output table
for id in $(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].InstanceId" --output text); do
    size=$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$id --query "sum(Volumes[*].Size)" --output text)
    echo "Instance: $id | Total EBS Size: ${size} GiB"
done

aws cloudwatch get-metric-data --metric-data-queries '[
  {
    "Id": "m1",
    "MetricStat": {
      "Metric": {
        "Namespace": "CWAgent",
        "MetricName": "disk_used_percent",
        "Dimensions": [
          {"Name": "InstanceId", "Value": "i-082ff8e3bb595af48"},
          {"Name": "device", "Value": "nvme0n1p1"}
        ]
      },
      "Period": 300,
      "Stat": "Average"
    }
  }
]' --start-time $(date -u -v-20m +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
