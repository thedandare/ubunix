export PROJECT_ID="fibodevop"
export REGION="southamerica-east1"
export BUCKET_NAME="${PROJECT_ID}-nixos-images"
export IMAGE_FAMILY="nixos-26-05-k7"
export IMAGE_NAME="${IMAGE_FAMILY}-$(date +%Y%m%d%H%M)"
export GCE_SYSTEM="gce"

gcloud auth login
gcloud config set project "$PROJECT_ID"

gcloud services enable compute.googleapis.com storage.googleapis.com

gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location="$REGION" || true

OUT_PATH="$(nix build --no-link --print-out-paths \
  ".#nixosConfigurations.${GCE_SYSTEM}.config.system.build.googleComputeImage")"

IMG_PATH="$(find "$OUT_PATH" -maxdepth 1 -name '*.tar.gz' -print -quit)"

test -n "$IMG_PATH"

gcloud storage cp "$IMG_PATH" "gs://${BUCKET_NAME}/${IMAGE_NAME}.raw.tar.gz"

gcloud compute images create "$IMAGE_NAME" \
  --project="$PROJECT_ID" \
  --source-uri="gs://${BUCKET_NAME}/${IMAGE_NAME}.raw.tar.gz" \
  --family="$IMAGE_FAMILY"