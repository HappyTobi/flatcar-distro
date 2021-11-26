#!/bin/bash
set -ex

# JOB_NAME will not fit within the character limit
NAME="jenkins-${BUILD_NUMBER}"

timeout=8h

set -o pipefail

# Construct the URLs of the image to be used during tests.
# KERNEL/CPIO_URL will be used by iPXE and so it will use http instead of https to
# make the boot process faster (except for signed URLs).
# IMAGE_URL is downloaded through Flatcar and can do SSL just fine, so that one
# can use https:// without a significant delay
if [[ "${DOWNLOAD_ROOT}" == gs://flatcar-jenkins-private/* ]]; then
  echo "Fetching google/cloud-sdk"
  docker pull google/cloud-sdk > /dev/null
  BUCKET_PATH="${DOWNLOAD_ROOT}/boards/${BOARD}/${FLATCAR_VERSION}"
  IMAGE_URL="$(docker run --rm --net=host -v "${GOOGLE_APPLICATION_CREDENTIALS}:${GOOGLE_APPLICATION_CREDENTIALS}" google/cloud-sdk sh -c "python3 -m pip install pyopenssl > /dev/null; gsutil signurl -d 7d -r us ${GOOGLE_APPLICATION_CREDENTIALS} ${BUCKET_PATH}/flatcar_production_packet_image.bin.bz2 | grep -o 'https.*'")"
  KERNEL_URL="$(docker run --rm --net=host -v "${GOOGLE_APPLICATION_CREDENTIALS}:${GOOGLE_APPLICATION_CREDENTIALS}" google/cloud-sdk sh -c "python3 -m pip install pyopenssl > /dev/null; gsutil signurl -d 7d -r us ${GOOGLE_APPLICATION_CREDENTIALS} ${BUCKET_PATH}/flatcar_production_pxe.vmlinuz | grep -o 'https.*'")"
  CPIO_URL="$(docker run --rm --net=host -v "${GOOGLE_APPLICATION_CREDENTIALS}:${GOOGLE_APPLICATION_CREDENTIALS}" google/cloud-sdk sh -c "python3 -m pip install pyopenssl > /dev/null; gsutil signurl -d 7d -r us ${GOOGLE_APPLICATION_CREDENTIALS} ${BUCKET_PATH}/flatcar_production_pxe_image.cpio.gz | grep -o 'https.*'")"
else
  BASE_PATH="bucket.release.flatcar-linux.net/$(echo $DOWNLOAD_ROOT | sed 's|gs://||g')/boards/${BOARD}/${FLATCAR_VERSION}"
  IMAGE_URL="https://${BASE_PATH}/flatcar_production_packet_image.bin.bz2"
  KERNEL_URL="http://${BASE_PATH}/flatcar_production_pxe.vmlinuz"
  CPIO_URL="http://${BASE_PATH}/flatcar_production_pxe_image.cpio.gz"
fi

if [[ "${KOLA_TESTS}" == "" ]]; then
  KOLA_TESTS="*"
fi

# Equinix Metal ARM server are not yet hourly available in the default `sv15` region
# so we override the `PACKET_REGION` to `Dallas` since it's available in this region.
# We do not override `PACKET_REGION` for both board on top level because we need to keep proximity
# for PXE booting.
# We override `PARALLEL_TESTS`, because kola run with PARALLEL_TESTS >= 4 causes the
# tests to provision >= 12 ARM servers at the same time. As the da11 region does not
# have that many free ARM servers, the whole tests will fail. With PARALLEL_TESTS=2
# the total number of servers stays < 10.
# In addition, we override `timeout` to 10 hours, because it takes more than 8 hours
# to run all tests only with 2 tests in parallel.
if [[ "${BOARD}" == "arm64-usr" ]]; then
  PACKET_REGION="da11"
  PARALLEL_TESTS="2"
  timeout=10h
fi

# Run the cl.internet test on multiple machine types only if it should run in general
cl_internet_included="$(set -o noglob; bin/kola list --platform=packet --filter ${KOLA_TESTS} | { grep cl.internet || true ; } )"
if [[ "${BOARD}" == "amd64-usr" ]] && [[ "${cl_internet_included}" != ""  ]]; then
  for INSTANCE in c3.medium.x86 m3.large.x86 s3.xlarge.x86 n2.xlarge.x86; do
    (
    OUTPUT=$(timeout --signal=SIGQUIT "${timeout}" bin/kola run \
    --basename="${NAME}" \
    --board="${BOARD}" \
    --channel="${GROUP}" \
    --gce-json-key="${UPLOAD_CREDS}" \
    --packet-api-key="${PACKET_API_KEY}" \
    --packet-facility="${PACKET_REGION}" \
    --packet-image-url="${IMAGE_URL}" \
    --packet-installer-image-kernel-url="${KERNEL_URL}" \
    --packet-installer-image-cpio-url="${CPIO_URL}" \
    --packet-project="${PACKET_PROJECT}" \
    --packet-storage-url="${UPLOAD_ROOT}/mantle/packet" \
    --packet-plan="${INSTANCE}" \
    --parallel="${PARALLEL_TESTS}" \
    --platform=packet \
    --tapfile="${JOB_NAME##*/}_validate_${INSTANCE}.tap" \
    --torcx-manifest=torcx_manifest.json \
    cl.internet 2>&1 || true)
    echo "=== START $INSTANCE ==="
    echo "${OUTPUT}" | sed "s/^/${INSTANCE}: /g"
    echo "=== END $INSTANCE ==="
    ) &
  done
fi

# Do not expand the kola test patterns globs
set -o noglob
timeout --signal=SIGQUIT "${timeout}" bin/kola run \
    --basename="${NAME}" \
    --board="${BOARD}" \
    --channel="${GROUP}" \
    --gce-json-key="${UPLOAD_CREDS}" \
    --packet-api-key="${PACKET_API_KEY}" \
    --packet-facility="${PACKET_REGION}" \
    --packet-image-url="${IMAGE_URL}" \
    --packet-installer-image-kernel-url="${KERNEL_URL}" \
    --packet-installer-image-cpio-url="${CPIO_URL}" \
    --packet-project="${PACKET_PROJECT}" \
    --packet-storage-url="${UPLOAD_ROOT}/mantle/packet" \
    --packet-plan="${PACKET_MACHINE_TYPE}" \
    --parallel="${PARALLEL_TESTS}" \
    --platform=packet \
    --tapfile="${JOB_NAME##*/}.tap" \
    --torcx-manifest=torcx_manifest.json \
    ${KOLA_TESTS}
set +o noglob

# wait for the cl.internet test results
wait