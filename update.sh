#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ---
OCP_VERSIONS=(4.12 4.13 4.14 4.15 4.16 4.17 4.18 4.19)

# Old (tag-based) image:
NEW_BUNDLE="quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-bundle-release@sha256:1b0bd69421d57bde932a3d2ea63dd2a59debad8aa7531ba37f7d00cc1512785b"

# New registry/repo to use, but we’ll attach the old image’s actual digest.
REDHAT_REGISTRY_REPO="registry.redhat.io/compliance/openshift-security-profiles-operator-bundle"

# (Optional) Some additional parameters you might use later
OP_V="0.9.0"
CSV_NEW="security-profiles-operator.v${OP_V}"
SKIP_RANGE=">=0.4.1 <${OP_V}"

echo "⏳ Determining digest for old image: ${NEW_BUNDLE}"
DIGEST="$(skopeo inspect "docker://${NEW_BUNDLE}" | jq -r '.Digest')"
if [[ -z "${DIGEST}" || "${DIGEST}" == "null" ]]; then
  echo "❌ ERROR: Could not find a valid digest for ${NEW_BUNDLE}"
  exit 1
fi

# Construct the new fully qualified image:
REDHAT_IMAGE="${REDHAT_REGISTRY_REPO}@${DIGEST}"
echo "✅ Found digest: ${DIGEST}"
echo "   New image reference will be: ${REDHAT_IMAGE}"
echo

for OCP_V in "${OCP_VERSIONS[@]}"; do
  CATALOG="catalog/v${OCP_V}/security-profiles-operator/catalog.yaml"

  if [[ ! -f "${CATALOG}" ]]; then
    echo "⚠️  Skipping ${OCP_V}: No ${CATALOG} found."
    continue
  fi

  echo "🔎 Updating ${CATALOG}…"

  # If an existing entry exists we should remove it so that we can generate a
  # fresh index with updated references. If we don't take this step, then we
  # could end up with two entries with the same release, which will fail opm
  # validation. Here we're removing the CSV_NEW entry entirely and the
  # relationship between the last version and the new version (e.g., CSV_NEW).
  yq eval-all -i "select(.name? != \"${CSV_NEW}\")" "${CATALOG}"
  yq eval -i "del(.entries[] | select(.name? == \"${CSV_NEW}\"))" "${CATALOG}"

  # 1) Find the "last" name in the release-alpha-rhel-8 channel's entries array.
  LAST_NAME=$(yq eval '
  select(.schema == "olm.channel" and .name == "release-alpha-rhel-8") |
  .entries[-1].name
  ' "${CATALOG}")

  echo "Last entry in release-alpha-rhel-8 channel is: ${LAST_NAME}"

  # # --- 1) Render the new bundle into a temp file ---
  if [[ "$OCP_V" =~ ("4.12"|"4.13"|"4.14"|"4.15"|"4.16") ]]; then
    opm render "${NEW_BUNDLE}" --output=yaml >> "${CATALOG}"
  else
    opm render "${NEW_BUNDLE}" --output=yaml --migrate-level bundle-object-to-csv-metadata >> "${CATALOG}"
  fi


  # 2) In-place update: remove any old entry named CSV_NEW, then add one new entry.
  yq eval -i -I1 "
  (select(.schema == \"olm.channel\" and .name == \"release-alpha-rhel-8\") | .entries) as \$entries |
  select(.schema == \"olm.channel\" and .name == \"release-alpha-rhel-8\").entries =
      (
      \$entries
      | map(select(.name != \"${CSV_NEW}\"))
      ) + [{
      \"name\":      \"${CSV_NEW}\",
      \"replaces\":  \"${LAST_NAME}\",
      \"skipRange\": \"${SKIP_RANGE}\"
      }]
  " "${CATALOG}"
  sed -i "s|${NEW_BUNDLE}|${REDHAT_IMAGE}|g" "${CATALOG}"

  echo "   Replaced ${NEW_BUNDLE} → ${REDHAT_IMAGE} in ${CATALOG}"

  # --- STEP 2 (Optional): Validate the updated catalog ---
  echo "   Validating updated catalog for OCP ${OCP_V}…"
  opm validate "catalog/v${OCP_V}/security-profiles-operator/" \
    && echo "   ✅ Validation passed." \
    || echo "   ❌ Validation warnings/errors."

  # --- STEP 3 (Optional): Convert to a template for reference ---
  opm alpha convert-template basic -o yaml "${CATALOG}" > "catalog/v${OCP_V}/catalog-template.yaml"
  echo "   Generated catalog-template.yaml."
  
  echo "✅ Done updating OCP ${OCP_V}!"
  echo
done

echo "🎉 All updates complete!"