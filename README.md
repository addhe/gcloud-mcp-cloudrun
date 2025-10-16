# Deploy gcloud-mcp ke Google Cloud Run

Dokumentasi singkat untuk folder ini. Berisi helper untuk membangun dan mendeploy MCP server `@google-cloud/gcloud-mcp` ke Cloud Run, serta skrip untuk testing deploy.

## Isi folder
- `deploy-cloudrun.sh` — helper script untuk build/push image ke Artifact Registry dan deploy ke Cloud Run.
- `Dockerfile` — Docker image yang menjalankan sebuah HTTP wrapper (`server.js`) yang memanggil bundle CLI `@google-cloud/gcloud-mcp`.
- `server.js` — HTTP wrapper: menerima request body, mem-spawn bundle CLI, mengirim stdin dan mengembalikan stdout sebagai response.
- `package.json` — mendeklarasikan dependency `@google-cloud/gcloud-mcp`.
- `test.sh` — smoke test untuk memverifikasi bahwa Cloud Run service sukses di-deploy dan merespon.

## Prasyarat (lokal)
- Docker (untuk build dan push image)
- gcloud CLI (authenticated dan project ter-set)
- Akses untuk membuat Artifact Registry repository dan Cloud Run service
- (Opsional) akses ke Secret Manager jika ingin menyimpan `GEMINI_API_KEY`

Pastikan Anda sudah login dan memilih project:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

## Environment variables yang dapat dikonfigurasi

Variabel ini digunakan oleh `deploy-cloudrun.sh` dan `test.sh`. Bila tidak di-set, skrip menggunakan nilai default (lihat keterangan).

- `PROJECT_ID` — (default: dari `gcloud config get-value project`) GCP project id.
- `REGION` — (default: `us-central1`) Region untuk Artifact Registry & Cloud Run.
- `SERVICE` — (default: `gcloud-mcp`) Nama Cloud Run service.
- `REPO` — (default: `gcloud-mcp`) Nama Artifact Registry repository.
- `PLATFORM` — (default: `linux/amd64`) target platform untuk `docker build --platform`.
- `GEMINI_API_KEY` — (opsional) API key yang akan dimasukkan ke Secret Manager `gemini-api-key`.
- `SERVICE_ACCOUNT` — (opsional) service account email yang akan dipakai oleh Cloud Run revision.

Tambahan variabel internal yang dapat Anda sesuaikan dalam skrip jika perlu: `MEMORY`, `TIMEOUT`.

## Cara deploy (cepat)

1. (Opsional) set environment variables yang diinginkan atau pass key sebagai arg pertama:

```bash
export PROJECT_ID=my-project
export REGION=asia-southeast2
export SERVICE=gcloud-mcp
export REPO=gcloud-mcp
# atau pass GEMINI key sebagai arg saat memanggil skrip
./deploy-cloudrun.sh "MY_GEMINI_KEY"
```

NOTE: Dockerfile sekarang mengharuskan `package-lock.json` yang di-commit untuk build yang dapat direproduksi. Sebelum menjalankan deploy/build, pastikan Anda menghasilkan dan meng-commit lockfile:

```bash
# jalankan secara lokal untuk membuat package-lock.json
npm install
# commit package-lock.json ke repo
git add package-lock.json && git commit -m "chore: add package-lock.json"
```

2. Skrip `deploy-cloudrun.sh` akan:
- Meng-enable layanan yang diperlukan (Artifact Registry, Cloud Run)
- Membuat Artifact Registry repo bila belum ada
- Build Docker image dan push ke `REGION-docker.pkg.dev/PROJECT/REPO/SERVICE:latest`
- Membuat atau menambahkan versi secret `gemini-api-key` bila parameter `GEMINI_API_KEY` diberikan
- Deploy Cloud Run service (meng-set secret `GEMINI_API_KEY` ke environment container jika tersedia)

## Cara test deploy

Jalankan `test.sh` untuk pengecekan cepat:

```bash
# gunakan overrides jika perlu
SERVICE=gcloud-mcp REGION=us-central1 PROJECT_ID=my-project ./test.sh
```

`test.sh` akan mencoba:
- Resolve URL service via `gcloud run services describe`.
- GET `/health` dan GET `/diag` (unauthenticated; jika gagal dan token tersedia, dicoba authenticated).
- Uji jalur cepat `run_gcloud_command`:
  - `--version` (output teks)
  - `run services list --format=json` (output JSON)
  - `run revisions list --service=$SERVICE --format=json` (output JSON)
- Jika ada langkah gagal, script akan menampilkan 50 baris log terakhir via `gcloud beta run services logs read`.

## Catatan penting

- `@google-cloud/gcloud-mcp` pada repository upstream memeriksa ketersediaan `gcloud` (CLI) pada saat runtime. Jika intent Anda adalah menjalankan fungsionalitas `gcloud` dari dalam container, pastikan container berisi Google Cloud SDK (`gcloud`).
  - Opsi mudah: gunakan base image resmi Cloud SDK (`gcr.io/google.com/cloudsdktool/cloud-sdk:slim`) dan install Node.js, atau install Cloud SDK di Dockerfile. Ini akan menaikkan ukuran image.
  - Alternatif: jika Anda hanya perlu MCP sebagai helper tanpa akses ke `gcloud` di dalam container, Anda harus memastikan fitur yang memanggil `gcloud` tidak dieksekusi, atau mock behavior tersebut.

- Desain saat ini menjalankan bundle CLI per-request (spawn). Untuk latensi lebih baik dan beban mesin lebih rendah, pertimbangkan menjalankan MCP server sebagai proses long-lived di container (jalankan bundle sekali saat container start, dan implement bridge request→stdio). Saya bisa bantu ubah `server.js` ke mode persistent jika Anda mau.

## Struktur Payload

Endpoint `POST /` menerima payload JSON dengan struktur spesifik untuk mengeksekusi command `gcloud`.

Payload harus berupa objek JSON dengan properti berikut:

- `tool`: String, harus diisi dengan `"run_gcloud_command"`.
- `input`: Objek yang berisi:
  - `args`: Array of strings, di mana setiap elemen adalah argumen untuk command `gcloud`.

### Contoh

Untuk menjalankan command `gcloud --version`, payload JSON yang dikirim adalah:

```json
{
  "tool": "run_gcloud_command",
  "input": {
    "args": ["--version"]
  }
}
```

Untuk menjalankan command `gcloud run services list --project=my-project --format=json`:

```json
{
  "tool": "run_gcloud_command",
  "input": {
    "args": ["run", "services", "list", "--project=my-project", "--format=json"]
  }
}
```

## Endpoint yang tersedia

- `GET /health` — mengembalikan JSON status layanan, contoh:

  ```json
  { "status": "ok", "time": "2025-09-26T12:27:34.200Z" }
  ```

- `GET /diag` — menjalankan `gcloud --version` dalam container dan mengembalikan hasilnya (text/plain).

- `POST /` — HTTP wrapper yang:
  - Jika body JSON cocok dengan pola `{"tool":"run_gcloud_command","input":{"args":[...]}}`, maka server akan menjalankan `gcloud` langsung dengan argumen tersebut dan mengembalikan hasilnya.
  - Jika tidak, body akan dipass-through ke `npx -y @google-cloud/gcloud-mcp` sebagai stdin, dan stdout bundle akan jadi respons.

### Contoh request `run_gcloud_command`

Versi gcloud (teks):

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"tool":"run_gcloud_command","input":{"args":["--version"]}}' \
  "$SERVICE_URL"/
```

Daftar layanan (JSON):

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"tool":"run_gcloud_command","input":{"args":["run","services","list","--project=YOUR_PROJECT","--region=YOUR_REGION","--format=json"]}}' \
  "$SERVICE_URL"/ | jq .
```

Daftar revisi untuk service aktif (JSON):

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"tool":"run_gcloud_command","input":{"args":["run","revisions","list","--project=YOUR_PROJECT","--region=YOUR_REGION","--service=YOUR_SERVICE","--format=json"]}}' \
  "$SERVICE_URL"/ | jq .
```

## Pengujian layanan privat (authenticated)

Jika layanan dibuat privat (tanpa akses publik), gunakan ID token saat melakukan request:

```bash
SERVICE_URL="https://<YOUR_SERVICE_URL>"
ID_TOKEN="$(gcloud auth print-identity-token --audiences=${SERVICE_URL})"
curl -i -H "Authorization: Bearer ${ID_TOKEN}" "${SERVICE_URL}/health"
```

## Troubleshooting cepat
- Jika image tidak bisa push: periksa autentikasi Docker →

```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

- Jika `gcloud run deploy` error: periksa permissions, apakah Artifact Registry dan Cloud Run API sudah di-enable untuk project.
- Jika container exit karena `gcloud` not found: tambahkan Cloud SDK ke Docker image (lihat Catatan penting di atas).

## Next steps (opsional)
- Tambah Cloud SDK ke `Dockerfile` (saya bisa update file untuk itu).
- Ubah `server.js` supaya menjalankan MCP server persistently dan gunakan internal queue/mux untuk melayani beberapa request.
- Menambahkan healthcheck endpoint pada `server.js` untuk Cloud Run readiness.

Jika ingin saya lakukan salah satu opsi di atas, beri tahu pilihan Anda (mis. "install Cloud SDK ke Dockerfile" atau "ubah server ke persistent mode").

## Menggunakan custom Service Account (disarankan)

Untuk keamanan dan kontrol akses, sangat disarankan menjalankan Cloud Run service Anda dengan sebuah custom Service Account (SA) khusus untuk MCP. Dengan SA khusus Anda bisa memberikan permission seminimal mungkin (least privilege) dan mengganti izin tanpa harus mengubah container image.

Saya sudah menambahkan sebuah helper script `deploy-service-account.sh` yang membuat SA dan memberikan beberapa role umum (viewer, logging.viewer). Script juga akan menambahkan akses `roles/secretmanager.secretAccessor` pada Secret `gemini-api-key` jika secret tersebut ada.

Contoh penggunaan script ini:

```bash
# set project jika belum
export PROJECT_ID=my-project
# jalankan script untuk membuat SA dan beri permission
./deploy-service-account.sh

# setelah script selesai, deploy Cloud Run dengan SA yang dibuat
gcloud run deploy $SERVICE --image $IMAGE_PATH --region $REGION --platform managed --service-account ${SA_EMAIL} --allow-unauthenticated
```

File `deploy-service-account.sh` melakukan operasi idempotent (mencoba buat SA hanya jika belum ada) dan akan menampilkan `SA_EMAIL` yang harus Anda pakai saat deploy.

Jika Anda butuh bantuan untuk menambahkan role tertentu ke SA (mis. akses ke Compute, Storage, Artifact Registry), beri tahu saya role spesifiknya dan saya dapat menambahkan flag/otomatisasi ke script.

### Menambahkan role tambahan ke Service Account

`deploy-service-account.sh` mendukung variabel lingkungan `EXTRA_ROLES` untuk memberikan role tambahan saat pembuatan SA. `EXTRA_ROLES` adalah daftar role terpisah-komma.

Contoh menambahkan akses Storage dan Artifact Registry:

```bash
PROJECT_ID=your-project SA_NAME=gcloud-mcp-sa EXTRA_ROLES="roles/storage.objectAdmin,roles/artifactregistry.writer" ./deploy-service-account.sh
```

Script akan menambahkan role-role tersebut ke SA selain role default (`roles/viewer`, `roles/logging.viewer`).
