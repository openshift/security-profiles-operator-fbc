#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ---
OCP_VERSIONS=(4.12 4.13 4.14 4.15 4.16 4.17 4.18 4.19)

# Old (tag-based) image:
NEW_BUNDLE="quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-bundle@sha256:4fc37a20974c89191f0c515f4abb30b26a2f11641682e2932fefed3850ae3a2c"

# New registry/repo to use, but we’ll attach the old image’s actual digest.
REDHAT_REGISTRY_REPO="registry.redhat.io/compliance/openshift-security-profiles-operator-bundle"

# (Optional) Some additional parameters you might use later
OP_V="0.9.0"
CSV_NEW="security-profiles-operator.v${OP_V}"
SKIP_RANGE=">=1.0.0 <${OP_V}"

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

  # # --- 1) Render the new bundle into a temp file ---
  opm render "${NEW_BUNDLE}" --output=yaml >> "${CATALOG}"


  # 1) Find the "last" name in the stable channel's entries array.
  LAST_NAME=$(yq eval '
  select(.schema == "olm.channel" and .name == "stable") |
  .entries[-1].name
  ' "${CATALOG}")

  echo "Last entry in stable channel is: ${LAST_NAME}"

  # 2) In-place update: remove any old entry named CSV_NEW, then add one new entry.
  yq eval -i -I1 "
  (select(.schema == \"olm.channel\" and .name == \"stable\") | .entries) as \$entries |
  select(.schema == \"olm.channel\" and .name == \"stable\").entries =
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