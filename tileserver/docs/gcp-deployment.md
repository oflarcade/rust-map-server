# Hosting Martin Tile Server on GCP

This guide covers two ways to run the Martin + Nginx tile server on Google Cloud Platform: **GCE VM** (simplest, fixed cost) and **Cloud Run** (serverless, scale-to-zero).

## Architecture

- **Martin** serves PMTiles (base tiles + boundary tiles) via HTTP range requests.
- **Nginx (OpenResty)** does tenant routing (`X-Tenant-ID` → source), Lua endpoints (GeoJSON, search, region lookup), and proxies tile requests to Martin.
- **Data**: Under the repo, use `data/pmtiles/`, `data/boundaries/`, `data/hdx/` (mounted into containers as `/data/pmtiles`, `/data/boundaries`, `/data/hdx`; see `tileserver/docker-compose.tenant.yml`).
- **Deploy helper**: From repo root, `./scripts/sh/deploy-gcp-view.sh` builds the Vue app with production `VITE_*` URLs and `gcloud compute scp`s `View/dist` to the VM. `./scripts/sh/deploy-gcp-lua.sh` uploads Lua modules; restart nginx on the VM afterward.

---

## Option 1: GCE VM (recommended for simplicity)

Run Docker Compose on a single VM. Data lives on a persistent disk or is copied at deploy time.

### 1.1 Prerequisites

- `gcloud` CLI installed and authenticated.
- A GCP project with billing enabled.

### 1.2 Create VM and attach disk (optional)

```bash
# Set your project and region
export PROJECT_ID=your-project-id
export REGION=us-central1
export ZONE=us-central1-a

gcloud config set project $PROJECT_ID

# Create a VM (e2-medium = 2 vCPU, 4 GB RAM; adjust as needed)
gcloud compute instances create martin-tileserver \
  --zone=$ZONE \
  --machine-type=e2-medium \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --tags=http-server

# Optional: create a separate disk for tile data (survives VM recreation)
gcloud compute disks create martin-data \
  --zone=$ZONE \
  --size=50GB \
  --type=pd-standard
gcloud compute instances attach-disk martin-tileserver \
  --zone=$ZONE \
  --disk=martin-data \
  --device-name=martin-data
```

### 1.3 SSH and install Docker

```bash
gcloud compute ssh martin-tileserver --zone=$ZONE

# On the VM:
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in for group to apply, or continue with sudo
```

### 1.4 Copy project and data to the VM

From your **local machine** (where you have the repo and generated tiles):

```bash
# From repo root
ZONE=us-central1-a
VM=martin-tileserver

# Copy repo (excluding large OSM/data if you don't need them on the VM)
rsync -avz --exclude 'data/' --exclude 'osm-data/' --exclude '.git' \
  . $VM:/home/$USER/rust-map-server/

# Copy tile data (compose expects repo-relative data/ directory)
mkdir -p data/pmtiles data/boundaries data/hdx
gcloud compute scp --zone=$ZONE --recurse \
  data/pmtiles data/boundaries data/hdx \
  $VM:/home/$USER/rust-map-server/data/
```

If you attached a data disk, format and mount it, then put `pmtiles/`, `boundaries/`, and `hdx/` there and point Docker at that path (see `docker-compose` below).

### 1.5 Run with Docker Compose on the VM

On the VM:

```bash
cd /home/$USER/rust-map-server

# Ensure paths exist (adjust if data is on a mounted disk, e.g. /mnt/data/pmtiles)
# Then start the stack (same compose file as local)
docker compose -f tileserver/docker-compose.tenant.yml up -d

# Check
curl -s http://localhost:8080/health
curl -s http://localhost:3000/catalog
```

### 1.6 Open HTTP and (optional) HTTPS

```bash
# Allow HTTP from the internet (for testing; restrict to your IP or use a load balancer)
gcloud compute firewall-rules create allow-http-8080 \
  --allow=tcp:8080 \
  --target-tags=http-server \
  --source-ranges=0.0.0.0/0

# Get external IP
gcloud compute instances describe martin-tileserver --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
# Test: curl -H "X-Tenant-ID: 1" http://<EXTERNAL_IP>:8080/health
```

For production, put an **HTTP(S) Load Balancer** in front (forward to port 8080), attach a static IP, and use a certificate for HTTPS.

---

## Option 2: Cloud Run (serverless)

Run the tile server as a single container on Cloud Run. Data can be **baked into the image** (simpler, limited by image size) or **mounted from a Cloud Storage bucket** (recommended for large or updatable data).

### 2.1 Build the GCP image

The image is Martin + Nginx in one container (see `tileserver/Dockerfile.gcp`). Data is **not** in the image; it is mounted at runtime.

From **repo root**:

```bash
# Build (from repo root so paths in Dockerfile work)
docker build -f tileserver/Dockerfile.gcp -t martin-tileserver .

# Tag for Artifact Registry
export PROJECT_ID=your-project-id
export REGION=us-central1
docker tag martin-tileserver $REGION-docker.pkg.dev/$PROJECT_ID/martin/martin-tileserver:latest
```

### 2.2 Push to Artifact Registry

```bash
# Create repo (once)
gcloud artifacts repositories create martin \
  --repository-format=docker \
  --location=$REGION

# Configure Docker for Artifact Registry
gcloud auth configure-docker $REGION-docker.pkg.dev

# Push
docker push $REGION-docker.pkg.dev/$PROJECT_ID/martin/martin-tileserver:latest
```

### 2.3 Upload tile data to Cloud Storage

Create a bucket and upload `pmtiles/`, `boundaries/`, and `hdx/` so Cloud Run can mount them.

```bash
export BUCKET=your-project-id-martin-data

gsutil mb -l $REGION gs://$BUCKET
gsutil -m cp -r pmtiles/* gs://$BUCKET/pmtiles/
gsutil -m cp -r boundaries/* gs://$BUCKET/boundaries/
gsutil -m cp -r hdx/* gs://$BUCKET/hdx/
```

### 2.4 Deploy to Cloud Run with GCS volume mount

Cloud Run (Gen 2) can mount a GCS bucket as a read-only volume. The container expects:

- `/data/pmtiles` → bucket path `pmtiles/`
- `/data/boundaries` → bucket path `boundaries/`
- `/data/hdx` → bucket path `hdx/`

```bash
# Deploy (beta for volume mounts)
gcloud beta run deploy martin-tileserver \
  --image=$REGION-docker.pkg.dev/$PROJECT_ID/martin/martin-tileserver:latest \
  --region=$REGION \
  --platform=managed \
  --execution-environment=gen2 \
  --allow-unauthenticated \
  --port=8080 \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=0 \
  --max-instances=10 \
  --add-volume=name=data,type=cloud-storage,bucket=$BUCKET \
  --add-volume-mount=volume=data,mount-path=/data
```

**Note:** With a single volume mount, the whole bucket is at `/data`. Your bucket layout must be:

- `gs://$BUCKET/pmtiles/` → `/data/pmtiles`
- `gs://$BUCKET/boundaries/` → `/data/boundaries`
- `gs://$BUCKET/hdx/` → `/data/hdx`

So the layout above is correct.

If your GCS FUSE/volume mount exposes only the bucket root at `/data`, then Martin and Nginx already expect `/data/pmtiles` and `/data/boundaries` and `/data/hdx` — so the structure in the bucket must match.

### 2.5 IAM for Cloud Run

The Cloud Run service identity needs **read** access to the bucket:

```bash
# Get service account (replace SERVICE_NAME and PROJECT_NUMBER)
gcloud run services describe martin-tileserver --region=$REGION --format='value(spec.template.spec.serviceAccountName)'
# If empty, it uses PROJECT_NUMBER-compute@developer.gserviceaccount.com

# Grant Storage Object Viewer
export SA=PROJECT_NUMBER-compute@developer.gserviceaccount.com
gsutil iam ch serviceAccount:$SA:objectViewer gs://$BUCKET
```

### 2.6 Get the URL and test

```bash
gcloud run services describe martin-tileserver --region=$REGION --format='value(status.url)'
# Test:
# curl -H "X-Tenant-ID: 1" https://<URL>/health
# curl -H "X-Tenant-ID: 1" https://<URL>/catalog
```

---

## Summary

| Option       | Pros                          | Cons                          |
|-------------|--------------------------------|-------------------------------|
| **GCE VM**  | Simple, same as local Docker   | You manage OS, scaling, LB    |
| **Cloud Run** | No VM management, scale-to-zero | Cold starts; GCS mount (beta); cost at scale |

- **Small team / predictable traffic:** GCE VM + Docker Compose is the fastest path.
- **Variable traffic / want no VM ops:** Use Cloud Run with GCS-backed data; ensure the service account can read the bucket and the bucket layout matches `/data/pmtiles`, `/data/boundaries`, `/data/hdx`.

## Security

- Restrict **firewall** (GCE) or **ingress** (Cloud Run) to your front end or VPN.
- Use **HTTPS** in production (Load Balancer for GCE; Cloud Run provides HTTPS by default).
- Keep **origin whitelist** in Nginx Lua aligned with your front-end origins (see `lua/origin-whitelist.lua`).
