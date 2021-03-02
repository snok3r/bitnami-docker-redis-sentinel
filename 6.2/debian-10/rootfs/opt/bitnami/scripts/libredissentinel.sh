#!/bin/bash
#
# Bitnami Redis Sentinel library

# shellcheck disable=SC1091

# Load Generic Libraries
. /opt/bitnami/scripts/libfile.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libnet.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libservice.sh
. /opt/bitnami/scripts/libvalidations.sh

# Functions

########################
# Set a configuration setting value
# Globals:
#   REDIS_SENTINEL_CONF_FILE
# Arguments:
#   $1 - key
#   $2 - value
# Returns:
#   None
#########################
redis_conf_set() {
    local key="${1:?missing key}"
    local value="${2:-}"

    # Sanitize inputs
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//\?/\\?}"
    [[ "$value" = "" ]] && value="\"$value\""

    if grep -q "^\s*$key .*" "$REDIS_SENTINEL_CONF_FILE"; then
        replace_in_file "$REDIS_SENTINEL_CONF_FILE" "^\s*${key} .*" "${key} ${value}" false
    else
        printf '\n%s %s' "$key" "$value" >> "$REDIS_SENTINEL_CONF_FILE"
    fi
}

########################
# Validate settings in REDIS_* env vars.
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_validate() {
    debug "Validating settings in REDIS_* env vars.."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }

    check_resolved_hostname() {
        if ! is_hostname_resolved "$1"; then
            warn "Hostname ${1} could not be resolved, this could lead to connection issues"
        fi
    }

    check_allowed_port() {
        local validate_port_args=()
        ! am_i_root && validate_port_args+=("-unprivileged")
        if ! err="$(validate_port "${validate_port_args[@]}" "${!1}")"; then
            print_validation_error "An invalid port was specified in the environment variable ${1}: ${err}"
        fi
    }

    [[ -w "$REDIS_SENTINEL_CONF_FILE" ]] || print_validation_error "The configuration file ${REDIS_SENTINEL_CONF_FILE} is not writable"

    is_positive_int "$REDIS_SENTINEL_QUORUM" || print_validation_error "Invalid quorum value (only positive integers allowed)"
    is_positive_int "$REDIS_SENTINEL_DOWN_AFTER_MILLISECONDS" || print_validation_error "Invalid down-after-milliseconds value (only positive integers allowed)"
    is_positive_int "$REDIS_SENTINEL_FAILOVER_TIMEOUT" || print_validation_error "Invalid failover-timeout value (only positive integers allowed)"

    check_allowed_port REDIS_SENTINEL_PORT_NUMBER
    check_resolved_hostname "$REDIS_MASTER_HOST"

    if is_boolean_yes "$REDIS_SENTINEL_TLS_ENABLED"; then
        if [[ "$REDIS_SENTINEL_PORT_NUMBER" == "$REDIS_SENTINEL_TLS_PORT_NUMBER" ]] && [[ "$REDIS_SENTINEL_PORT_NUMBER" != "26379" ]]; then
            # If both ports are assigned the same numbers and they are different to the default settings
            print_validation_error "Environment variables REDIS_SENTINEL_PORT_NUMBER and REDIS_SENTINEL_TLS_PORT_NUMBER point to the same port number (${REDIS_SENTINEL_PORT_NUMBER}). Change one of them or disable non-TLS traffic by setting REDIS_SENTINEL_PORT_NUMBER=0"
        fi
        if [[ -z "$REDIS_SENTINEL_TLS_CERT_FILE" ]]; then
            print_validation_error "You must provide a X.509 certificate in order to use TLS"
        elif [[ ! -f "$REDIS_SENTINEL_TLS_CERT_FILE" ]]; then
            print_validation_error "The X.509 certificate file in the specified path ${REDIS_SENTINEL_TLS_CERT_FILE} does not exist"
        fi
        if [[ -z "$REDIS_SENTINEL_TLS_KEY_FILE" ]]; then
            print_validation_error "You must provide a private key in order to use TLS"
        elif [[ ! -f "$REDIS_SENTINEL_TLS_KEY_FILE" ]]; then
            print_validation_error "The private key file in the specified path ${REDIS_SENTINEL_TLS_KEY_FILE} does not exist"
        fi
        if [[ -z "$REDIS_SENTINEL_TLS_CA_FILE" ]]; then
            print_validation_error "You must provide a CA X.509 certificate in order to use TLS"
        elif [[ ! -f "$REDIS_SENTINEL_TLS_CA_FILE" ]]; then
            print_validation_error "The CA X.509 certificate file in the specified path ${REDIS_SENTINEL_TLS_CA_FILE} does not exist"
        fi
        if [[ -n "$REDIS_SENTINEL_TLS_DH_PARAMS_FILE" ]] && [[ ! -f "$REDIS_SENTINEL_TLS_DH_PARAMS_FILE" ]]; then
            print_validation_error "The DH param file in the specified path ${REDIS_SENTINEL_TLS_DH_PARAMS_FILE} does not exist"
        fi
    fi

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Check if redis is running
# Globals:
#   REDIS_BASE_DIR
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_redis_sentinel_running() {
    local pid
    pid="$(get_pid_from_file "$REDIS_SENTINEL_PID_FILE")"

    if [[ -z "$pid" ]]; then
        false
    else
        is_service_running "$pid"
    fi
}

########################
# Check if redis is not running
# Globals:
#   REDIS_BASE_DIR
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_redis_sentinel_not_running() {
    ! is_redis_sentinel_running
}

########################
# Ensure Redis is initialized
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_initialize() {
    info "Initializing Redis Sentinel..."

    # Give the daemon user appropriate permissions
    if am_i_root; then
        for dir in "$REDIS_SENTINEL_CONF_DIR" "$REDIS_SENTINEL_LOG_DIR" "$REDIS_SENTINEL_TMP_DIR" "$REDIS_SENTINEL_VOLUME_DIR"; do
            chown -R "${REDIS_SENTINEL_DAEMON_USER}:${REDIS_SENTINEL_DAEMON_GROUP}" "$dir"
        done
    fi

    if [[ ! -f "${REDIS_SENTINEL_VOLUME_DIR}/conf/sentinel.conf" ]]; then
        info "Configuring Redis Sentinel..."

        [[ -z "$REDIS_SENTINEL_PASSWORD" ]] || redis_conf_set "requirepass" "$REDIS_SENTINEL_PASSWORD"

        # Master set
        redis_conf_set "sentinel monitor" "${REDIS_MASTER_SET} ${REDIS_MASTER_HOST} ${REDIS_MASTER_PORT_NUMBER} ${REDIS_SENTINEL_QUORUM}"
        redis_conf_set "sentinel down-after-milliseconds" "${REDIS_MASTER_SET} ${REDIS_SENTINEL_DOWN_AFTER_MILLISECONDS}"
        redis_conf_set "sentinel failover-timeout" "${REDIS_MASTER_SET} ${REDIS_SENTINEL_FAILOVER_TIMEOUT}"
        redis_conf_set "sentinel parallel-syncs" "${REDIS_MASTER_SET} 1"
        redis_conf_set "sentinel resolve-hostnames" "${REDIS_SENTINEL_RESOLVE_HOSTNAMES}"
        [[ -z "$REDIS_MASTER_PASSWORD" ]] || redis_conf_set "sentinel auth-pass" "${REDIS_MASTER_SET} ${REDIS_MASTER_PASSWORD}"
        [[ -z "$REDIS_MASTER_USER" ]] || redis_conf_set "sentinel auth-user" "${REDIS_MASTER_SET} ${REDIS_MASTER_USER}"
        [[ -z "$REDIS_SENTINEL_ANNOUNCE_IP" ]] || redis_conf_set "sentinel announce-ip" "${REDIS_SENTINEL_ANNOUNCE_IP}"
        [[ -z "$REDIS_SENTINEL_ANNOUNCE_PORT" ]] || redis_conf_set "sentinel announce-port" "${REDIS_SENTINEL_ANNOUNCE_PORT}"

        # Sentinel Configuration (maybe overwritten by more specific init blocks like TLS configuration)
        redis_conf_set port "$REDIS_SENTINEL_PORT_NUMBER"

        # TLS configuration
        if is_boolean_yes "$REDIS_SENTINEL_TLS_ENABLED"; then
            if [[ "$REDIS_SENTINEL_PORT_NUMBER" ==  "26379" ]] && [[ "$REDIS_SENTINEL_TLS_PORT_NUMBER" ==  "26379" ]]; then
                # If both ports are set to default values, enable TLS traffic only
                redis_conf_set port 0
                redis_conf_set tls-port "$REDIS_SENTINEL_TLS_PORT_NUMBER"
            else
                # Different ports were specified
                redis_conf_set port "$REDIS_SENTINEL_PORT_NUMBER"
                redis_conf_set tls-port "$REDIS_SENTINEL_TLS_PORT_NUMBER"
            fi
            redis_conf_set tls-cert-file "$REDIS_SENTINEL_TLS_CERT_FILE"
            redis_conf_set tls-key-file "$REDIS_SENTINEL_TLS_KEY_FILE"
            redis_conf_set tls-ca-cert-file "$REDIS_SENTINEL_TLS_CA_FILE"
            [[ -n "$REDIS_SENTINEL_TLS_DH_PARAMS_FILE" ]] && redis_conf_set tls-dh-params-file "$REDIS_SENTINEL_TLS_DH_PARAMS_FILE"
            redis_conf_set tls-auth-clients "$REDIS_SENTINEL_TLS_AUTH_CLIENTS"
            redis_conf_set tls-replication yes
        fi

        cp -pf "$REDIS_SENTINEL_CONF_FILE" "${REDIS_SENTINEL_VOLUME_DIR}/conf/sentinel.conf"
    else
        info "Persisted files detected, restoring..."
    fi

    rm -rf "$REDIS_SENTINEL_CONF_DIR"
    ln -sf "${REDIS_SENTINEL_VOLUME_DIR}/conf" "$REDIS_SENTINEL_CONF_DIR"
}