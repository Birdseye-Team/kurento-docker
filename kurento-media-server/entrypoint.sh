#!/usr/bin/env bash

#/ Docker script - Run Kurento Media Server.

# Bash options for strict error checking
set -o errexit -o errtrace -o pipefail -o nounset

# Trace all commands
set -o xtrace

# Trap functions
function on_error {
    echo "[Docker entrypoint] ERROR ($?)"
    exit 1
}
trap on_error ERR

# Settings
BASE_RTP_FILE="/etc/kurento/modules/kurento/BaseRtpEndpoint.conf.ini"
WEBRTC_FILE="/etc/kurento/modules/kurento/WebRtcEndpoint.conf.ini"

# Check root permissions -- Overriding the Docker container run user (e.g. with
# `docker run --user=1234`) is not supported, because this entrypoint script
# needs to edit root-owned files under "/etc".
# Instead, run with `docker run -e KMS_UID=1234`.
[[ "$(id -u)" -eq 0 ]] || {
    echo "[Docker entrypoint] ERROR: Please run container as root user. Use '-e KMS_UID=1234' instead of '--user=1234'."
    exit 1
}

# Aux function: set value to a given parameter
function set_parameter {
    # Assignments fail if any argument is missing (set -o nounset)
    local FILE="$1"
    local PARAM="$2"
    local VALUE="$3"

    local COMMENT=";"  # Kurento .ini files use ';' for comment lines
    local REGEX="^${COMMENT}?\s*${PARAM}=.*"

    if grep --extended-regexp -q "$REGEX" "$FILE"; then
        sed --regexp-extended -i "s|${REGEX}|${PARAM}=${VALUE}|" "$FILE"
    else
        echo "${PARAM}=${VALUE}" >>"$FILE"
    fi
}

# BaseRtpEndpoint settings
if [[ -n "${KMS_MIN_PORT:-}" ]]; then
    set_parameter "$BASE_RTP_FILE" "minPort" "$KMS_MIN_PORT"
fi
if [[ -n "${KMS_MAX_PORT:-}" ]]; then
    set_parameter "$BASE_RTP_FILE" "maxPort" "$KMS_MAX_PORT"
fi
if [[ -n "${KMS_MTU:-}" ]]; then
    set_parameter "$BASE_RTP_FILE" "mtu" "$KMS_MTU"
fi

# WebRtcEndpoint settings
if [[ -n "${KMS_EXTERNAL_IPV4:-}" ]]; then
    if [[ "$KMS_EXTERNAL_IPV4" == "auto" ]]; then
        if IP="$(/getmyip.sh --ipv4)"; then
            set_parameter "$WEBRTC_FILE" "externalIPv4" "$IP"
        fi
    else
        set_parameter "$WEBRTC_FILE" "externalIPv4" "$KMS_EXTERNAL_IPV4"
    fi
fi
if [[ -n "${KMS_EXTERNAL_IPV6:-}" ]]; then
    if [[ "$KMS_EXTERNAL_IPV6" == "auto" ]]; then
        if IP="$(/getmyip.sh --ipv6)"; then
            set_parameter "$WEBRTC_FILE" "externalIPv6" "$IP"
        fi
    else
        set_parameter "$WEBRTC_FILE" "externalIPv6" "$KMS_EXTERNAL_IPV6"
    fi
fi
if [[ -n "${KMS_NETWORK_INTERFACES:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "networkInterfaces" "$KMS_NETWORK_INTERFACES"
fi
if [[ -n "${KMS_ICE_TCP:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "iceTcp" "$KMS_ICE_TCP"
fi
if [[ -n "${KMS_STUN_IP:-}" ]] && [[ -n "${KMS_STUN_PORT:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "stunServerAddress" "$KMS_STUN_IP"
    set_parameter "$WEBRTC_FILE" "stunServerPort" "$KMS_STUN_PORT"
fi
if [[ -n "${KMS_TURN_URL:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "turnURL" "$KMS_TURN_URL"
fi
if [[ -n "${KMS_PEM_CERTIFICATE_RSA:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "pemCertificateRSA" "$KMS_PEM_CERTIFICATE_RSA"
fi
if [[ -n "${KMS_PEM_CERTIFICATE_ECDSA:-}" ]]; then
    set_parameter "$WEBRTC_FILE" "pemCertificateECDSA" "$KMS_PEM_CERTIFICATE_ECDSA"
fi
# Remove the IPv6 loopback until IPv6 is well supported in KMS.
# Notes:
# - `cat /etc/hosts | sed | tee` because `sed -i /etc/hosts` won't work inside a
#   Docker container.
# - `|| true` to avoid errors if the container is not run with the root user.
#   E.g. `docker run --user=1234`.
# shellcheck disable=SC2002
cat /etc/hosts | sed '/::1/d' | tee /etc/hosts >/dev/null || true

# Debug logging -- If empty or unset, use suggested levels
# https://doc-kurento.readthedocs.io/en/latest/features/logging.html#suggested-levels
if [[ -z "${GST_DEBUG:-}" ]]; then
    export GST_DEBUG="2,Kurento*:4,kms*:4,sdp*:4,webrtc*:4,*rtpendpoint:4,rtp*handler:4,rtpsynchronizer:4,agnosticbin:4"
fi

# Error logging (stderr)
# If a logs path has been set, use it to redirect stderr.
KURENTO_ERR_FILE=""
function parse_logs_path {
    # Try with the env var, `KURENTO_LOGS_PATH`.
    if [[ -n "${KURENTO_LOGS_PATH:-}" ]]; then
        KURENTO_ERR_FILE="$KURENTO_LOGS_PATH/errors.log"
        return
    fi

    # Try with the call arguments.
    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --logs-path|-d)
                if [[ -n "${2-}" ]]; then
                    KURENTO_ERR_FILE="$2/errors.log"
                    return
                fi
                ;;
        esac
        shift
    done
}
parse_logs_path "$@"

# Disable output colors when running without a terminal.
# This prevents terminal control codes from ending up in Docker log storage.
if [ ! -t 1 ]; then
    # This shell is not attached to a TTY.
    export GST_DEBUG_NO_COLOR=1
fi

# Find the full path to the Jemalloc library file.
JEMALLOC_PATH="$(find /usr/lib/x86_64-linux-gnu/ | grep 'libjemalloc\.so\.[[:digit:]]' | head -n 1)"

# Pass these settings string to Jemalloc.
JEMALLOC_CONF="abort_conf:true,confirm_conf:true,background_thread:true,metadata_thp:always"

# Run Kurento Media Server, changing to requested User/Group ID (if any).
function run_kurento {
    local RUN_UID; RUN_UID="$(id -u)"

    if [[ -n "${KMS_UID:-}" && "$KMS_UID" != "$RUN_UID" ]]; then
        echo "[Docker entrypoint] Start Kurento Media Server, UID: $KMS_UID"

        groupmod \
            --gid "$KMS_UID" \
            kurento

        usermod \
            --uid "$KMS_UID" \
            --gid "$KMS_UID" \
            kurento

        # `exec` replaces the current shell process, running Kurento as PID 1.
        # `setpriv` sets the given User/Group ID for the process.
        # `env` sets environment variables for the process.
        exec setpriv --reuid kurento --regid kurento --init-groups env \
        LD_PRELOAD="$JEMALLOC_PATH" \
        MALLOC_CONF="$JEMALLOC_CONF" \
        /usr/bin/kurento-media-server "$@"
    else
        echo "[Docker entrypoint] Start Kurento Media Server, UID: $RUN_UID"

        # `exec` replaces the current shell process, running Kurento as PID 1.
        # `env` sets environment variables for the process.
        exec env \
        LD_PRELOAD="$JEMALLOC_PATH" \
        MALLOC_CONF="$JEMALLOC_CONF" \
        /usr/bin/kurento-media-server "$@"
    fi
}

if [[ -n "$KURENTO_ERR_FILE" ]]; then
    echo -e "\n\n$(date --iso-8601=seconds) -- New execution" >>"$KURENTO_ERR_FILE"
    run_kurento "$@" 2>>"$KURENTO_ERR_FILE"
else
    run_kurento "$@"
fi
