#!/usr/bin/env bash
set -euo pipefail

for region in $(aws ec2 describe-regions --query "Regions[].RegionName" --output text); do
  [[ "$region" != sa-east-1* && "$region" != us-east-2* ]] && continue
  aws ec2 describe-instances --region "$region" \
      --query "Reservations[*].Instances[*].[Placement.AvailabilityZone, InstanceId, NetworkInterfaces[*].Association.PublicIp]" \
      --output text 2>/dev/null \
    | awk -F'\t' -v r="$region" '
      /^None$/ || /^$/ { next }
      NF == 2 { zone=$1; id=$2; next }
      NF == 1 && $1 != "None" { printf "%s\t%s\t%s\n", zone, id, $1 }
    '
done | sort -u
