#! /bin/bash
set -x
OCP_VERSIONS=4.17
for VERSION in ${OCP_VERSIONS}
do
    CONTAINERFILE="Containerfile-rhel-9.in"
    if [[ "$VERSION" =~ ("4.12"|"4.13"|"4.14") ]]; then
            CONTAINERFILE="Containerfile-rhel-8.in"
    fi

    opm migrate "registry.redhat.io/redhat/redhat-operator-index:v${VERSION}" "./catalog-migrate-${VERSION}"
    mkdir -p "catalog/v${VERSION}/security-profiles-operator"
    cp "${CONTAINERFILE}" "catalog/v${VERSION}/Containerfile"
    sed -i "s/OCP_VERSION/${VERSION}/g" "catalog/v${VERSION}/Containerfile"
    opm alpha convert-template basic -o yaml "./catalog-migrate-${VERSION}/security-profiles-operator/catalog.json" > "catalog/v${VERSION}/catalog-template.yaml"
    opm alpha render-template basic -o yaml "catalog/v${VERSION}/catalog-template.yaml" > "catalog/v${VERSION}/security-profiles-operator/catalog.yaml"

    echo "Building locally to ensure it works"
    podman build -t "fio-fbc-${VERSION}" -f "catalog/v${VERSION}/Containerfile" "catalog/v${VERSION}/" && rm -rf "./catalog-migrate-${VERSION}"
done
