set -euo pipefail

export PROJECT_ID="project-1ab07399-29ab-4352-8f8"
export REGION="southamerica-west1"
export BUCKET_NAME="${PROJECT_ID}-nixos-images"
export IMAGE_FAMILY="nixos-26-05-k7"
export IMAGE_NAME="${IMAGE_FAMILY}-$(date +%Y%m%d%H%M)"
export GCE_SYSTEM="gce"

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
  gcloud auth login
fi
gcloud config set project "$PROJECT_ID"

gcloud services enable compute.googleapis.com storage.googleapis.com

gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location="$REGION" || true

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

OUT_PATH="$(
  nix-build '<nixpkgs/nixos>' \
    -A config.system.build.googleComputeImage \
    -I nixos-config="$SCRIPT_DIR/gce.nix" \
    --no-out-link
)"

IMG_PATH="$(find "$OUT_PATH" -maxdepth 1 -name '*.tar.gz' -print -quit)"

test -n "$IMG_PATH"

gcloud storage cp "$IMG_PATH" "gs://${BUCKET_NAME}/${IMAGE_NAME}.raw.tar.gz"

gcloud compute images create "$IMAGE_NAME" \
  --project="$PROJECT_ID" \
  --source-uri="gs://${BUCKET_NAME}/${IMAGE_NAME}.raw.tar.gz" \
  --family="$IMAGE_FAMILY"

echo "nixos_image_self_link=projects/${PROJECT_ID}/global/images/${IMAGE_NAME}"