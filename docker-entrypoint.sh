#!/usr/bin/dumb-init /bin/bash

# copy from https://github.com/sc250024/docker-elastalert/blob/master/src/docker-entrypoint.sh

set -eo pipefail

__install_plugin_dependencies() {
    # reinstall plugin's' dependencies 
    if [ -f "${ELASTALERT_PLUGIN_DIRECTORY}\requirements.txt" ]; then
        echo "=> ${scriptName}: Plugins will install dependencies by ${ELASTALERT_PLUGIN_DIRECTORY}\requirements.txt ... "
        pip install -r "${ELASTALERT_PLUGIN_DIRECTORY}\requirements.txt"
    else
        echo "=> ${scriptName}: Plugins dependencies ${ELASTALERT_PLUGIN_DIRECTORY}\requirements.txt not exist. Skipping install dependencies"
    fi
}

__install_enhancement_dependencies() {
    # reinstall enhancement's dependencies 
    if [ -f "${ELASTALERT_ENHANCEMENT_DIRECTORY}\requirements.txt" ]; then
        echo "=> ${scriptName}: Enhancements will install dependencies by ${ELASTALERT_ENHANCEMENT_DIRECTORY}\requirements.txt ... "
        pip install -r "${ELASTALERT_ENHANCEMENT_DIRECTORY}\requirements.txt"
    else
        echo "=> ${scriptName}: Enhancements dependencies ${ELASTALERT_ENHANCEMENT_DIRECTORY}\requirements.txt not exist. Skipping install dependencies"
    fi
}

__check_rules() {
    # Check the rules and see if they are valid; otherwise, exit
    if [ "$(ls "${ELASTALERT_RULES_DIRECTORY}")" ]; then
        find "${ELASTALERT_RULES_DIRECTORY}/" -type f -name "*.yaml" -o -name "*.yml" > /tmp/rulelist
        while IFS= read -r file; do
            echo "=> ${scriptName}: Checking syntax on Elastalert rule ${file}..."
            elastalert-test-rule \
                --schema-only \
                --stop-error \
                "${file}"
        done < /tmp/rulelist
        rm /tmp/rulelist
    else
        echo "=> ${scriptName}: Rules folder ${ELASTALERT_RULES_DIRECTORY} is empty. Skipping checking"
    fi
}

__config_timezone_and_ntp() {
    # Set the timezone.
    if echo "${SET_CONTAINER_TIMEZONE}" | grep -q '[Tt]rue'; then
        cp "/usr/share/zoneinfo/${CONTAINER_TIMEZONE}" /etc/localtime && \
        echo "${CONTAINER_TIMEZONE}" > /etc/timezone && \
        echo "=> ${scriptName}: Container timezone set to: ${CONTAINER_TIMEZONE}"
    else
        echo "=> ${scriptName}: Container timezone not modified"
    fi

    # Force immediate synchronisation of the time and start the time-synchronization service.
    # In order to be able to use ntpd in the container, it must be run with the SYS_TIME capability.
    # In addition you may want to add the SYS_NICE capability, in order for ntpd to be able to modify its priority.
    ntpd
}

__create_elastalert_index() {
    # Check if the Elastalert index exists in Elasticsearch and create it if it does not.
	if ! curl -f "${protocol}${basicAuth}${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/${ELASTALERT_INDEX}" >/dev/null 2>&1
    then
        echo "=> ${scriptName}: Creating Elastalert index in Elasticsearch..."
        elastalert-create-index "${createEaOptions}" \
            --config "${ELASTALERT_CONFIG}" \
            --host "${ELASTICSEARCH_HOST}" \
            --index "${ELASTALERT_INDEX}" \
            --old-index "" \
            --port "${ELASTICSEARCH_PORT}"
    else
        echo "=> ${scriptName}: Elastalert index \`${ELASTALERT_INDEX}\` already exists in Elasticsearch."
    fi
}

__set_elastalert_config() {
    # Elastalert config template:
    echo "=> ${scriptName}: Creating Elastalert config file from template..."
    dockerize -template "${ELASTALERT_HOME}/config.yaml.tpl" \
        | grep -Ev "^[[:space:]]*#|^$" \
        | uniq > "${ELASTALERT_CONFIG}"
}

__set_folder_permissions() {
    if [ "$(stat -c %u "${ELASTALERT_HOME}")" != "$(id -u "${ELASTALERT_SYSTEM_USER}")" ]; then
        chown -R "${ELASTALERT_SYSTEM_USER}":"${ELASTALERT_SYSTEM_GROUP}" "${ELASTALERT_HOME}"
    fi
    if [ "$(stat -c %u "${ELASTALERT_RULES_DIRECTORY}")" != "$(id -u "${ELASTALERT_SYSTEM_USER}")" ]; then
        chown -R "${ELASTALERT_SYSTEM_USER}":"${ELASTALERT_SYSTEM_GROUP}" "${ELASTALERT_RULES_DIRECTORY}"
    fi
}

__set_script_variables() {
    # Set name of the script for logging purposes
    scriptName="$(basename "${0}")"

    # Set schema and elastalert options
    case "${ELASTICSEARCH_USE_SSL}:${ELASTICSEARCH_VERIFY_CERTS}" in
        "True:True")
            protocol="https://"
            createEaOptions="--ssl --verify-certs"
        ;;
        "True:False")
            protocol="https://"
            createEaOptions="--ssl --no-verify-certs"
        ;;
        *)
            protocol="http://"
            createEaOptions="--no-ssl"
        ;;
    esac

    # Set authentication if needed
    if [ -n "${ELASTICSEARCH_USER}" ] && [ -n "${ELASTICSEARCH_PASSWORD}" ]; then
        basicAuth="${ELASTICSEARCH_USER}:${ELASTICSEARCH_PASSWORD}@"
    else
        basicAuth=""
    fi
}

__start_elastalert() {
    echo "=> ${scriptName}: Starting Elastalert..."
    exec su-exec "${ELASTALERT_SYSTEM_USER}":"${ELASTALERT_SYSTEM_GROUP}" \
         python -u -m elastalert.elastalert \
             --config "${ELASTALERT_CONFIG}" \
             --verbose
}

__wait_for_elasticsearch() {
    ELASTICSEARCH_HOST=es.lonsid.cn
    ELASTICSEARCH_PORT=80
    protocol=http://
    # Wait until Elasticsearch is online since otherwise Elastalert will fail.
    while true;
    do
        echo "=> ${scriptName}: Waiting for Elasticsearch..."
    	curl "${protocol}${basicAuth}${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}" 2>/dev/null && break
        sleep 1
    done
}

init() {
    __set_script_variables
    __install_enhancement_dependencies
    __install_plugin_dependencies
    __set_elastalert_config
    __set_folder_permissions
    __check_rules
    __config_timezone_and_ntp
    __wait_for_elasticsearch
    __create_elastalert_index
    __start_elastalert
}

if [ "${1}" == "check-rules" ]; then
    __set_script_variables
    __install_enhancement_dependencies
    __install_plugin_dependencies
    __set_elastalert_config
    __set_folder_permissions
    __check_rules
    exit 0
fi

init

exec "$@"
