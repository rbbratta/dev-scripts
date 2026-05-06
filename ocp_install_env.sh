source release_info.sh

eval "$(go env)"

_DEV_SCRIPTS_FETCH_BMC="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
# shellcheck disable=SC1091
source "${_DEV_SCRIPTS_FETCH_BMC}/fetch_bmc_certs.inc.sh"

# Indent PEM file for install-config YAML; avoid sudo when readable.
function indent_install_config_pem() {
  local pem="$1"
  if [[ -r "${pem}" ]]; then
    sed 's/^/      /' "${pem}"
  else
    sudo sed 's/^/      /' "${pem}"
  fi
}

# Early fail in 05_create_install_config.sh when HTTPS BMCs need trust material.
function preflight_bmc_tls_ca_bundle() {
  if is_lower_version "$(openshift_version $OCP_DIR)" "4.22"; then
    return 0
  fi
  local out NEED=0 cafile
  if ! out=$(fetch_bmc_certs_invoke_print_needs_tls_for_ocp); then
    echo "ERROR: BMC inventory TLS check failed (fetch_bmc_certs.inc.sh):" >&2
    echo "${out}" >&2
    return 1
  fi
  [[ "${out}" == "yes" ]] && NEED=1
  if [[ "${NEED}" -eq 0 ]]; then
    return 0
  fi
  cafile="${WORKING_DIR}/virtualbmc/sushy-tools/cert.pem"
  if [[ -n "${BMC_CA_OVERRIDE:-}" ]]; then
    cafile="${BMC_CA_OVERRIDE}"
  fi
  if [[ -s "${cafile}" ]] || [[ -n "${SKIP_BMC_VERIFY_CA_CHECK:-}" ]]; then
    return 0
  fi
  {
    echo "ERROR: OCP $(openshift_version $OCP_DIR) with HTTPS BMC inventory that keeps certificate verification enabled"
    echo "needs a non-empty BMC CA bundle at:"
    echo "  ${cafile}"
    echo "Right now that file is missing or zero bytes."
    echo ""
    echo "Populate it before install_config (the Makefile install_config target runs this step)."
    echo "  make fetch_bmc_certs"
    echo "That loads your dev-scripts config (e.g. config_${USER}.sh) and writes cert.pem under WORKING_DIR."
    echo ""
    echo "If fetch fails with permission denied under ${WORKING_DIR}:"
    printf '  sudo mkdir -p "%s/virtualbmc/sushy-tools" && sudo chown -R "$USER" "%s/virtualbmc"\n' "${WORKING_DIR}" "${WORKING_DIR}"
    echo "or set WORKING_DIR in your config to a directory you own, then run make fetch_bmc_certs again."
    echo ""
    echo "If your inventory sets driver_info.redfish_verify_ca=false, install-config should not require this bundle."
    echo "Alternatives: BMC_CA_OVERRIDE=/path/to/bundle.pem   or   SKIP_BMC_VERIFY_CA_CHECK=1 (unsafe for private BMC CAs)."
  } >&2
  return 1
}

function get_arch() {
    ARCH=$(uname -m)
    if [[ $ARCH == "aarch64" ]]; then
        ARCH="arm64"
    elif [[ $ARCH == "x86_64" ]]; then
        if [[ "$1" == "install_config" ]]; then
	    ARCH="amd64"
        fi
    fi
    echo $ARCH
}

function extract_command() {
    local release_image
    local cmd
    local outdir
    local extract_dir
    local MAX_RETRIES=5
    local SLEEP_BETWEEN=10

    cmd="$1"
    release_image="$2"
    outdir="$3"

    # Retry loop for oc adm release extract to handle quay.io blips
    for attempt in $(seq 1 $MAX_RETRIES); do
        extract_dir=$(mktemp --tmpdir -d "installer--XXXXXXXXXX")

        if oc adm release extract --registry-config "${PULL_SECRET_FILE}" --command="$cmd" --to "${extract_dir}" "${release_image}"; then
            echo "Successfully extracted $cmd"
            break
        fi

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo "Extraction failed, retrying in ${SLEEP_BETWEEN}s..."
            rm -rf "${extract_dir}"
            sleep "${SLEEP_BETWEEN}"
        else
            echo "Failed to extract $cmd from ${release_image} after $MAX_RETRIES attempts"
            return 1
        fi
    done

    _tmpfiles="$_tmpfiles $extract_dir"

    mkdir -p "${outdir}"
    mv "${extract_dir}/${cmd}" "${outdir}/"
}

# Let's always grab the `oc` from the release we're using.
function extract_oc() {
    extract_dir=$(mktemp --tmpdir -d "installer--XXXXXXXXXX")
    _tmpfiles="$_tmpfiles $extract_dir"
    extract_command oc "$1" "${extract_dir}"
    sudo mv "${extract_dir}/oc" /usr/local/bin
}

function extract_rhcos_json() {
    local release_image
    local outdir

    release_image="$1"
    outdir="$2"

    baremetal_image=$(image_for baremetal-installer)
    baremetal_container=$(podman create --authfile "$PULL_SECRET_FILE" "$baremetal_image")

    # This is OK to fail as rhcos.json isn't available in every release,
    # we'll download it from github if it's not available
    podman cp "$baremetal_container":/var/cache/rhcos.json "$outdir" || true

    podman rm -f "$baremetal_container"
}

function baremetal_network_configuration() {
  if [[ "$(openshift_version $OCP_DIR)" == "4.3" ]]; then
    return
  fi

  if [[ "$PROVISIONING_NETWORK_PROFILE" == "Disabled" ]]; then
cat <<EOF
    provisioningNetwork: "${PROVISIONING_NETWORK_PROFILE}"
EOF
    if printf '%s\n4.6\n' "$(openshift_version)" | sort -V -C; then
cat <<EOF
    provisioningHostIP: "${CLUSTER_PROVISIONING_IP}"
    bootstrapProvisioningIP: "${BOOTSTRAP_PROVISIONING_IP}"
EOF
    fi
  else
cat <<EOF
    provisioningBridge: ${PROVISIONING_NETWORK_NAME}
    provisioningNetworkCIDR: $PROVISIONING_NETWORK
    provisioningNetworkInterface: $CLUSTER_PRO_IF
EOF
  fi

  if [ -n "${ENABLE_BOOTSTRAP_STATIC_IP}" ]; then
    if [[ "${IP_STACK}" = "v6" || "${IP_STACK}" = "v6v4" ]]; then
      BOOTSTRAP_IP=$(nth_ip $EXTERNAL_SUBNET_V6 $((idx + 9)))
    else
      BOOTSTRAP_IP=$(nth_ip $EXTERNAL_SUBNET_V4 $((idx + 9)))
    fi
cat <<EOF
    bootstrapExternalStaticIP: "${BOOTSTRAP_IP}"
    bootstrapExternalStaticGateway: "${PROVISIONING_HOST_EXTERNAL_IP}"
EOF
    if ! printf '%s\n4.13\n' "$(openshift_version)" | sort -V -C; then
cat <<EOF
    bootstrapExternalStaticDNS: "${PROVISIONING_HOST_EXTERNAL_IP}"
EOF
    fi
  fi
}

function dnsvip() {
  # dnsVIP was removed from 4.5
  if printf '%s\n4.4\n' "$(openshift_version)" | sort -V -C; then
cat <<EOF
    dnsVIP: ${DNS_VIP}
EOF
  fi
}

function external_mac() {
  if [ -n "$EXTERNAL_BOOTSTRAP_MAC" ] ; then
cat <<EOF
    externalMACAddress: $EXTERNAL_BOOTSTRAP_MAC
EOF
  fi
}


function renderVIPs() {
    # Arguments:
    #     First argument: field name
    #     Second argument: value for the field
    #
    # Description:
    #     This function helps to write in a YAML format multiple resources. (i.e: apiVIPs and ingressVIPs)
    #     Example: apiVIPs, "192.168.11.5, fd2e:6f44:5dd8:c956::15"
    #
    # Returns:
    #     YAML formatted resource
    FIELD_VALUES="${2}";

    echo "    ${1}"
    for data in ${FIELD_VALUES//${VIPS_SEPARATOR}/ }; do
        echo "    - ${data}"
    done
}

function setVIPs() {
    # Arguments:
    #     The type of VIP: apivips OR ingressvips
    #
    # Description:
    #     apiVIP and ingressVIP both has been DEPRECATED in 4.12 in favor of apiVIPs and ingressVIPs.
    #     This functions helps to write the new apiVIPs/ingressVIPs format or set the old fields.
    #
    # Returns:
    #     The YAML formatted APIVIP or INGRESSVIP (supports new and old format)
    case "${1}" in
    "apivips")
        if printf '4.12\n%s\n' "$(openshift_version)" | sort -V -C; then
            # OCP version is equals or newer as 4.12 and supports the new VIPs fields
            renderVIPs "apiVIPs:" "${API_VIPS}"
        else
            # OCP version is older as 4.12 and does not support the new VIPs fields
            echo "    apiVIP: ${API_VIPS%${VIPS_SEPARATOR}*}"
        fi
    ;;
    "ingressvips")
        if printf '4.12\n%s\n' "$(openshift_version)" | sort -V -C; then
            # OCP version is equals or newer as 4.12 and supports the new VIPs fields
            renderVIPs "ingressVIPs:" "${INGRESS_VIPS}"
        else
            # OCP version is older as 4.12 and does not support the new VIPs fields
            echo "    ingressVIP: ${INGRESS_VIPS%${VIPS_SEPARATOR}*}"
        fi
    ;;
    esac
}

function loadbalancer_type() {
    if [ -n "$EXTERNAL_LOADBALANCER" ]; then
cat <<EOF
    loadBalancer:
      type: UserManaged
    dnsRecordsType: External
EOF
    fi
}

function featureSet() {
    if [[ -n "$FEATURE_SET" ]]; then
cat <<EOF
featureSet: "$FEATURE_SET"
EOF
    fi
}

function featureGates() {
    if [[ -n "$FEATURE_GATES" ]]; then
cat <<EOF
featureGates:
EOF
        for gate in ${FEATURE_GATES//,/ }; do
cat <<EOF
- $gate
EOF
        done
    fi
}

function osImageStream() {
    if [[ -n "$OS_IMAGE_STREAM" ]]; then
cat <<EOF
osImageStream: "$OS_IMAGE_STREAM"
EOF
    fi
}

function capabilities_stanza() {
    if [[ -n "$BASELINE_CAPABILITY_SET" ]]; then
cat <<EOF
capabilities:
  baselineCapabilitySet: "$BASELINE_CAPABILITY_SET"
EOF
    fi

    if [[ -n "$BASELINE_CAPABILITY_SET" ]] && [[ -n "$ADDITIONAL_CAPABILITIES" ]]; then
cat << EOF
  additionalEnabledCapabilities:
EOF

      for cap in ${ADDITIONAL_CAPABILITIES//,/ }; do
cat << EOF
  - ${cap}
EOF
      done

    elif [[ -n "$ADDITIONAL_CAPABILITIES" ]] && [[ -z "$BASELINE_CAPABILITY_SET" ]]; then
      echo "Additional capabilities is set to: $ADDITIONAL_CAPABILITIES, but no desired BASELINE_CAPABILITY_SET is set"
      exit 1
    fi
}

function arbiter_stanza() {
    if [[ ${NUM_ARBITERS} -gt 0 ]]; then
cat <<EOF
arbiter:
  name: arbiter
  replicas: ${NUM_ARBITERS}
  hyperthreading: Enabled
  architecture: $(get_arch install_config)
  platform:
    baremetal: {}
EOF
    fi
}

function workload_partitioning() {
  if [[ -n "${ENABLE_WORKLOAD_PARTITIONING}" ]]; then
cat <<EOF
cpuPartitioningMode: AllNodes
EOF
  fi
}

function libvirturi() {
    if [[ "$REMOTE_LIBVIRT" -ne 0 ]]; then
cat <<EOF
    libvirtURI: qemu+ssh://${PROVISIONING_HOST_USER}@$(wrap_if_ipv6 ${PROVISIONING_HOST_IP})/system
EOF
    fi
}

function additional_trust_bundle() {
  if [[ ! -z "$ADDITIONAL_TRUST_BUNDLE" ]]; then
    if [[ -z "${MIRROR_IMAGES}" || "${MIRROR_IMAGES,,}" != "false" ]] && [[ -z "${ENABLE_LOCAL_REGISTRY}" ]]; then
      echo "additionalTrustBundle: |"
    fi
    awk '{ print " ", $0 }' "${ADDITIONAL_TRUST_BUNDLE}"
  fi
}

function cluster_network() {
  if [[ "${IP_STACK}" == "v4" ]]; then
cat <<EOF
  machineNetwork:
  - cidr: ${EXTERNAL_SUBNET_V4}
  clusterNetwork:
  - cidr: ${CLUSTER_SUBNET_V4}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V4}
  serviceNetwork:
  - ${SERVICE_SUBNET_V4}
EOF
  elif [[ "${IP_STACK}" == "v6" ]]; then
cat <<EOF
  machineNetwork:
  - cidr: ${EXTERNAL_SUBNET_V6}
  clusterNetwork:
  - cidr: ${CLUSTER_SUBNET_V6}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V6}
  serviceNetwork:
  - ${SERVICE_SUBNET_V6}
EOF
  elif [[ "${IP_STACK}" == "v4v6" ]]; then
cat <<EOF
  machineNetwork:
  - cidr: ${EXTERNAL_SUBNET_V4}
  - cidr: ${EXTERNAL_SUBNET_V6}
  clusterNetwork:
  - cidr: ${CLUSTER_SUBNET_V4}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V4}
  - cidr: ${CLUSTER_SUBNET_V6}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V6}
  serviceNetwork:
  - ${SERVICE_SUBNET_V4}
  - ${SERVICE_SUBNET_V6}
EOF
  elif [[ "${IP_STACK}" == "v6v4" ]]; then
cat <<EOF
  machineNetwork:
  - cidr: ${EXTERNAL_SUBNET_V6}
  - cidr: ${EXTERNAL_SUBNET_V4}
  clusterNetwork:
  - cidr: ${CLUSTER_SUBNET_V6}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V6}
  - cidr: ${CLUSTER_SUBNET_V4}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V4}
  serviceNetwork:
  - ${SERVICE_SUBNET_V6}
  - ${SERVICE_SUBNET_V4}
EOF
  else
    echo "Unexpected IP_STACK value: '${IP_STACK}'"
    exit 1
  fi
}

function override_openshift_sdn_deprecation() {
  # OpenShiftSDN is deprecated in 4.15 and later; if the user explicitly requests it,
  # we will override this deprecation (but not if they just defaulted to it).
  [[ "${ORIG_NETWORK_TYPE}" = "OpenShiftSDN" ]] && openshift_sdn_deprecated
}

function cluster_os_image() {
  if is_lower_version $(openshift_version) 4.10; then
cat <<EOF
    clusterOSImage: http://$(wrap_if_ipv6 $MIRROR_IP)/images/${MACHINE_OS_IMAGE_NAME}?sha256=${MACHINE_OS_IMAGE_SHA256}
EOF
  fi
}

function generate_ocp_install_config() {
    local outdir

    outdir="$1"

    # when using local mirror set pull secret to just this mirror to
    # ensure we don't accidentally pull from upstream
    if [[ ! -z "${MIRROR_IMAGES}" && "${MIRROR_IMAGES,,}" != "false" ]]; then
        install_config_pull_secret="${REGISTRY_CREDS}"
    else
        install_config_pull_secret="${PULL_SECRET_FILE}"
    fi

    mkdir -p "${outdir}"

    # IPv6 network config validation
    if [[ -n "${EXTERNAL_SUBNET_V6}" ]]; then
      if [[ "${NETWORK_TYPE}" != "OVNKubernetes" ]]; then
        echo "NETWORK_TYPE must be OVNKubernetes when using IPv6"
        exit 1
      fi
    fi

    if override_openshift_sdn_deprecation; then
      # Claim we want OVNKubernetes in install-config; we will hack the generated
      # manifests later if OpenShiftSDN was explicitly requested.
      NETWORK_TYPE=OVNKubernetes
    fi

    cat > "${outdir}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
$(workload_partitioning)
networking:
  networkType: ${NETWORK_TYPE}
$(cluster_network)
metadata:
  name: ${CLUSTER_NAME}
compute:
- name: worker
  replicas: $NUM_WORKERS
  architecture: $(get_arch install_config)
controlPlane:
  name: master
  replicas: ${NUM_MASTERS}
  architecture: $(get_arch install_config)
  platform:
    baremetal: {}
$(node_map_to_install_config_fencing_credentials)
$(arbiter_stanza)
$(featureSet)
$(featureGates)
$(osImageStream)
$(capabilities_stanza)
platform:
  baremetal:
$(libvirturi)
$(baremetal_network_configuration)
    externalBridge: ${BAREMETAL_NETWORK_NAME}
$(external_mac)
    bootstrapOSImage: http://$(wrap_if_ipv6 $MIRROR_IP)/images/${MACHINE_OS_BOOTSTRAP_IMAGE_NAME}?sha256=${MACHINE_OS_BOOTSTRAP_IMAGE_UNCOMPRESSED_SHA256}
$(cluster_os_image)
$(setVIPs apivips)
$(setVIPs ingressvips)
$(dnsvip)
$(loadbalancer_type)
    hosts:
EOF

  if [ -z "${HOSTS_SWAP_DEFINITION:-}" ]; then
    cat >> "${outdir}/install-config.yaml" << EOF
$(node_map_to_install_config_hosts $NUM_MASTERS 0 master)
$(node_map_to_install_config_hosts $NUM_ARBITERS $NUM_MASTERS arbiter)
$(node_map_to_install_config_hosts $NUM_WORKERS $(( NUM_MASTERS + NUM_ARBITERS )) worker)
EOF
  else
    cat >> "${outdir}/install-config.yaml" << EOF
$(node_map_to_install_config_hosts $NUM_WORKERS $(( NUM_MASTERS + NUM_ARBITERS )) worker)
$(node_map_to_install_config_hosts $NUM_ARBITERS $NUM_MASTERS arbiter)
$(node_map_to_install_config_hosts $NUM_MASTERS 0 master)
EOF
  fi

  if ! is_lower_version "$(openshift_version $OCP_DIR)" "4.22"; then
    NEED_TLS_BMC_CA=0
    TLS_CHECK_OUT=""
    if ! TLS_CHECK_OUT=$(fetch_bmc_certs_invoke_print_needs_tls_for_ocp); then
      echo "ERROR: could not classify BMC URLs for TLS (fetch_bmc_certs_invoke_print_needs_tls_for_ocp):" >&2
      echo "${TLS_CHECK_OUT}" >&2
      exit 1
    fi
    if [[ "${TLS_CHECK_OUT}" == "yes" ]]; then
      NEED_TLS_BMC_CA=1
    elif [[ "${TLS_CHECK_OUT}" != "no" ]]; then
      echo "ERROR: unexpected output from fetch_bmc_certs inventory check: ${TLS_CHECK_OUT}" >&2
      exit 1
    fi

    BMC_CA_FILE="${WORKING_DIR}/virtualbmc/sushy-tools/cert.pem"
    if [[ -n "${BMC_CA_OVERRIDE:-}" ]]; then
      if [[ ! -s "${BMC_CA_OVERRIDE}" ]]; then
        echo "ERROR: BMC_CA_OVERRIDE points to missing or empty file: ${BMC_CA_OVERRIDE}" >&2
        exit 1
      fi
      BMC_CA_FILE="${BMC_CA_OVERRIDE}"
    fi

    if [[ "${NEED_TLS_BMC_CA}" -eq 1 ]]; then
      if [[ -s "${BMC_CA_FILE}" ]]; then
    cat >> "${outdir}/install-config.yaml" << EOF
    bmcVerifyCA: |
$(indent_install_config_pem "${BMC_CA_FILE}")
EOF
      elif [[ -z "${SKIP_BMC_VERIFY_CA_CHECK:-}" ]]; then
cat <<BADBLOCK >&2
ERROR: BMC CA bundle missing or empty: ${BMC_CA_FILE}
OpenShift bare metal IPI on OCP >= 4.22 verifies TLS to HTTPS Redfish/BMC endpoints
when your inventories use those URLs and keep redfish_verify_ca enabled.

Populate the default sushy-tools bundle (respects WORKING_DIR, NODES_FILE,
EXTRA_NODES_FILE, ARM_NODES_FILE):

  make fetch_bmc_certs

or:

  ./fetch_bmc_certs.sh

Or pass an existing PEM bundle:

  BMC_CA_OVERRIDE=/path/to/bmc-bundle.pem

Escape hatch (omits bmcVerifyCA; unsafe for self-signed BMC HTTPS):

  SKIP_BMC_VERIFY_CA_CHECK=1
BADBLOCK
        exit 1
      else
        echo "WARNING: Skipping baremetal.bmcVerifyCA (empty/missing ${BMC_CA_FILE}) because SKIP_BMC_VERIFY_CA_CHECK is set but inventory uses HTTPS BMC URLs." >&2
      fi
    fi
  fi

    cat >> "${outdir}/install-config.yaml" << EOF
$(image_mirror_config)
$(additional_trust_bundle)
pullSecret: |
  $(jq -c . $install_config_pull_secret)
sshKey: |
  ${SSH_PUB_KEY}
fips: ${FIPS_MODE:-false}
EOF

  if [[ ! -z "$INSTALLER_PROXY" ]]; then

    cat >> "${outdir}/install-config.yaml" << EOF
proxy:
  httpProxy: ${HTTP_PROXY}
  httpsProxy: ${HTTPS_PROXY}
  noProxy: ${NO_PROXY}
EOF
  fi

    cp "${outdir}/install-config.yaml" "${outdir}/install-config.yaml.save"
}

function generate_ocp_host_manifest() {
    local outdir

    outdir="$1"
    host_input="$2"
    host_output="$3"
    namespace="$4"

    mkdir -p "${outdir}"
    rm -f "${outdir}/extra_hosts.yaml"

    mkdir -p "${outdir}/extras"
    rm -f "${outdir}/extras/*"

    worker_index=0
    jq --raw-output '.[] | .name + " " + .ports[0].address + " " + .driver_info.username + " " + .driver_info.password + " " + .driver_info.address + " " + .driver_info.redfish_verify_ca + " " + .properties.cpu_arch' $host_input \
       | while read name mac username password address verify_ca architecture; do

        encoded_username=$(echo -n "$username" | base64)
        encoded_password=$(echo -n "$password" | base64)
        # Heads up, "verify_ca" in ironic driver config, and
        # "disableCertificateVerification" in BMH have opposite meaning.
        # Keep honoring redfish_verify_ca on all supported versions because some
        # real BMC certs do not have SANs matching the configured hostname.
        disableCertificateVerification=$([[ "${verify_ca,,}" = "false" ]] && echo "true" || echo "false")

        secret="---
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-bmc-secret
  namespace: $namespace
type: Opaque
data:
  username: $encoded_username
  password: $encoded_password
"
        bmh="---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: $name
  namespace: $namespace
spec:
  online: ${EXTRA_WORKERS_ONLINE_STATUS}
  bootMACAddress: $mac
  architecture: $architecture
  bmc:
    address: $address
    credentialsName: ${name}-bmc-secret
    disableCertificateVerification: ${disableCertificateVerification}"

        echo "${secret}${bmh}" >> "${outdir}/${host_output}"

        # Extra files will be used later to generate a secret used by e2e tests
        echo "${secret}" >> "${outdir}/extras/extraworker-${worker_index}-secret"
        echo "${bmh}" >> "${outdir}/extras/extraworker-${worker_index}-bmh"
        ((worker_index+=1))
    done
}
