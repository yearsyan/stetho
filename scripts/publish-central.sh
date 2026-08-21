#!/usr/bin/env bash
set -euo pipefail

required_variables=(SONATYPE_AUTH_TOKEN GPG_PRIVATE_KEY GPG_PASSWORD)
for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required environment variable: ${variable}" >&2
    exit 1
  fi
done

for command_name in curl gpg md5sum sha1sum zip; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
done

repository_root="${HOME}/.m2/repository"
group_id="$(sed -n 's/^GROUP=//p' gradle.properties)"
version="$(sed -n 's/^VERSION_NAME=//p' gradle.properties)"

if [[ "${group_id}" != "io.github.yearsyan" ]]; then
  echo "Unexpected Maven group: ${group_id}" >&2
  exit 1
fi

if [[ -z "${version}" ]]; then
  echo "VERSION_NAME is not configured" >&2
  exit 1
fi

artifacts=(
  stetho
  stetho-urlconnection
  stetho-okhttp3
  stetho-js-rhino
  stetho-timber
)

work_directory="$(mktemp -d)"
staging_directory="${work_directory}/staging"
bundle_file="${work_directory}/stetho-${version}-central.zip"
group_path="${group_id//.//}"

cleanup() {
  rm -rf -- "${work_directory}"
}
trap cleanup EXIT

printf '%s' "${GPG_PRIVATE_KEY}" | gpg --batch --import

for artifact in "${artifacts[@]}"; do
  source_directory="${repository_root}/${group_path}/${artifact}/${version}"
  target_directory="${staging_directory}/${group_path}/${artifact}/${version}"
  base_name="${artifact}-${version}"
  files=(
    "${source_directory}/${base_name}.aar"
    "${source_directory}/${base_name}.pom"
    "${source_directory}/${base_name}-sources.jar"
    "${source_directory}/${base_name}-javadoc.jar"
  )

  mkdir -p "${target_directory}"

  for source_file in "${files[@]}"; do
    if [[ ! -f "${source_file}" ]]; then
      echo "Missing Maven artifact: ${source_file}" >&2
      exit 1
    fi

    target_file="${target_directory}/$(basename "${source_file}")"
    cp "${source_file}" "${target_file}"
    printf '%s' "${GPG_PASSWORD}" | gpg \
      --batch \
      --yes \
      --pinentry-mode loopback \
      --passphrase-fd 0 \
      --armor \
      --detach-sign \
      --output "${target_file}.asc" \
      "${target_file}"
    md5sum "${target_file}" | cut -d' ' -f1 > "${target_file}.md5"
    sha1sum "${target_file}" | cut -d' ' -f1 > "${target_file}.sha1"
  done

  pom_file="${target_directory}/${base_name}.pom"
  grep -q "<groupId>${group_id}</groupId>" "${pom_file}"
  if grep -q '<groupId>com.facebook.stetho</groupId>' "${pom_file}"; then
    echo "Official Stetho coordinates leaked into ${artifact}." >&2
    exit 1
  fi
done

(
  cd "${staging_directory}"
  zip -9 -q -r "${bundle_file}" "io"
)

echo "Uploading ${group_id} Stetho ${version} to Maven Central..."
deployment_id="$(curl \
  --fail \
  --silent \
  --show-error \
  --connect-timeout 60 \
  --retry 3 \
  --request POST \
  --header "Authorization: Bearer ${SONATYPE_AUTH_TOKEN}" \
  --form "bundle=@${bundle_file}" \
  "https://central.sonatype.com/api/v1/publisher/upload?publishingType=AUTOMATIC&name=stetho-${version}" \
  | tr -d '"')"

if [[ -z "${deployment_id}" ]]; then
  echo "Maven Central did not return a deployment ID" >&2
  exit 1
fi

echo "Maven Central deployment ID: ${deployment_id}"
