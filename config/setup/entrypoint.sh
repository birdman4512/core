#!/usr/bin/env bash
#
# CORE setup container for Elasticsearch.
#
# Responsibilities (all idempotent, safe to re-run):
#   1. Generate a private CA and per-instance TLS certificates with
#      elasticsearch-certutil (es01/es02/es03, kibana, logstash).
#   2. Lay the certificates out on the shared volume with secure ownership
#      and permissions (private keys are NOT world readable).
#   3. Wait for the Elasticsearch cluster to come up.
#   4. Set the kibana_system password so Kibana can authenticate.
#   5. Create a least-privilege logstash_writer role + user for log ingest.
#
# The container's healthcheck reports "healthy" as soon as the node
# certificates exist, which lets the es0x services start while this script
# continues on to configure passwords against the running cluster.

set -eu
set -o pipefail

### Configuration
########################

CERT_DIR="/certs"                       # shared volume, no trailing slash
CA_DIR="${CERT_DIR}/ca"                 # CA cert + key (key never leaves here)
CA_SHARE_DIR="${CERT_DIR}/ca-share"     # only the CA cert, mounted into services
CERT_DAYS="${CERT_DAYS:-730}"

ES_HOST="${ELASTICSEARCH_HOST:-es01}"
ES_PORT="${ELASTICSEARCH_PORT:-9200}"
ES_URL="https://${ES_HOST}:${ES_PORT}"

# The Elasticsearch, Kibana, and Logstash images all run as uid/gid 1000.
SERVICE_UID=1000
SERVICE_GID=1000

# Instances that need a certificate. Each gets DNS SANs of its service name
# (used inside the docker network) plus localhost. "client" is a generic client
# certificate used by the configure phase (and ad-hoc admin curl) now that the
# Elasticsearch HTTP layer requires mutual TLS.
INSTANCES=(es01 es02 es03 kibana logstash client)

# Client certificate presented to Elasticsearch by the configure phase.
CLIENT_CERT="${CERT_DIR}/client/client.pem"
CLIENT_KEY="${CERT_DIR}/client/client.key"

### Logging helpers
########################

log()    { echo "[+] $1"; }
sublog() { echo "   - $1"; }
err()    { echo "[x] $1" >&2; }

### Certificate generation
########################

generate_ca() {
	if [ -f "${CA_DIR}/ca.crt" ] && [ -f "${CA_DIR}/ca.key" ]; then
		sublog 'CA already exists, reusing it.'
		return
	fi

	log 'Creating Certificate Authority'
	mkdir -p "${CERT_DIR}"
	bin/elasticsearch-certutil ca \
		--silent --pem \
		--days "${CERT_DAYS}" \
		--out "${CERT_DIR}/ca.zip"
	unzip -o -q "${CERT_DIR}/ca.zip" -d "${CERT_DIR}"
	rm -f "${CERT_DIR}/ca.zip"
	sublog 'CA created.'
}

generate_certs() {
	# If every instance already has a cert, there is nothing to do.
	local missing=0
	for name in "${INSTANCES[@]}"; do
		[ -f "${CERT_DIR}/${name}/${name}.pem" ] || missing=1
	done
	if [ "${missing}" -eq 0 ]; then
		sublog 'Instance certificates already exist, reusing them.'
		return
	fi

	log 'Creating instance certificates'

	# Build an instances.yml describing the SANs for each certificate.
	local instances_file="${CERT_DIR}/instances.yml"
	echo 'instances:' > "${instances_file}"
	for name in "${INSTANCES[@]}"; do
		{
			echo "  - name: ${name}"
			echo "    dns:"
			echo "      - ${name}"
			echo "      - localhost"
			echo "    ip:"
			echo "      - 127.0.0.1"
		} >> "${instances_file}"
	done

	bin/elasticsearch-certutil cert \
		--silent --pem \
		--days "${CERT_DAYS}" \
		--in "${instances_file}" \
		--ca-cert "${CA_DIR}/ca.crt" \
		--ca-key "${CA_DIR}/ca.key" \
		--out "${CERT_DIR}/certs.zip"
	unzip -o -q "${CERT_DIR}/certs.zip" -d "${CERT_DIR}"
	rm -f "${CERT_DIR}/certs.zip" "${instances_file}"

	# certutil writes <name>/<name>.crt; the rest of the stack expects .pem.
	for name in "${INSTANCES[@]}"; do
		mv -f "${CERT_DIR}/${name}/${name}.crt" "${CERT_DIR}/${name}/${name}.pem"
	done

	# Logstash's beats input and elasticsearch output require PKCS#8 keys, but
	# certutil emits PKCS#1, so convert Logstash's key in place.
	openssl pkcs8 -topk8 -nocrypt -inform PEM -outform PEM \
		-in "${CERT_DIR}/logstash/logstash.key" \
		-out "${CERT_DIR}/logstash/logstash.pkcs8.key"
	mv -f "${CERT_DIR}/logstash/logstash.pkcs8.key" "${CERT_DIR}/logstash/logstash.key"

	sublog 'Instance certificates created.'
}

publish_ca() {
	# Share ONLY the CA certificate (never the CA key) with service containers.
	mkdir -p "${CA_SHARE_DIR}"
	cp -f "${CA_DIR}/ca.crt" "${CA_SHARE_DIR}/ca.pem"
}

secure_permissions() {
	log 'Applying certificate ownership and permissions'
	chown -R "${SERVICE_UID}:${SERVICE_GID}" "${CERT_DIR}"
	# Directories are traversable by all; secrets are protected at the file level.
	find "${CERT_DIR}" -type d -exec chmod 755 {} \;
	# Public certificates may be world readable; private keys must not be.
	find "${CERT_DIR}" -type f -name '*.pem' -exec chmod 644 {} \;
	find "${CERT_DIR}" -type f -name '*.key' -exec chmod 640 {} \;
	# The CA private key stays locked down and is never mounted into a service.
	chmod 600 "${CA_DIR}/ca.key"
	sublog 'Permissions applied (keys 640, CA key 600).'
}

### Cluster configuration
########################

wait_for_elasticsearch() {
	log 'Waiting for Elasticsearch to be reachable'
	local code=""
	for _ in $(seq 1 60); do
		code="$(curl -s -o /dev/null -w '%{http_code}' \
			--cacert "${CA_DIR}/ca.crt" \
			--cert "${CLIENT_CERT}" --key "${CLIENT_KEY}" \
			"${ES_URL}" || true)"
		# 200 (open) or 401 (auth required) both mean the HTTP layer is up.
		if [ "${code}" = "200" ] || [ "${code}" = "401" ]; then
			sublog 'Elasticsearch is up.'
			return 0
		fi
		sublog "Not ready yet (last status: ${code:-none}). Retrying in 5s."
		sleep 5
	done
	err "Elasticsearch did not become available at ${ES_URL}"
	return 1
}

set_kibana_password() {
	log 'Setting kibana_system password'
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' \
		--cacert "${CA_DIR}/ca.crt" \
		--cert "${CLIENT_CERT}" --key "${CLIENT_KEY}" \
		-u "elastic:${ELASTIC_PASSWORD}" \
		-X POST "${ES_URL}/_security/user/kibana_system/_password" \
		-H 'Content-Type: application/json' \
		-d "{\"password\":\"${KIBANA_PASSWORD}\"}")"
	if [ "${code}" = "200" ]; then
		sublog 'kibana_system password set.'
	else
		err "Failed to set kibana_system password (status: ${code})"
		return 1
	fi
}

create_logstash_user() {
	log 'Creating least-privilege logstash_writer role and user'

	# Role: only what an ingest pipeline needs against the logstash-* indices.
	curl -s -o /dev/null -w '   - role status: %{http_code}\n' \
		--cacert "${CA_DIR}/ca.crt" \
		--cert "${CLIENT_CERT}" --key "${CLIENT_KEY}" \
		-u "elastic:${ELASTIC_PASSWORD}" \
		-X PUT "${ES_URL}/_security/role/logstash_writer" \
		-H 'Content-Type: application/json' \
		-d '{
			"cluster": ["monitor"],
			"indices": [
				{
					"names": ["logstash-*"],
					"privileges": ["create_index", "create", "write", "index", "auto_configure"]
				}
			]
		}'

	curl -s -o /dev/null -w '   - user status: %{http_code}\n' \
		--cacert "${CA_DIR}/ca.crt" \
		--cert "${CLIENT_CERT}" --key "${CLIENT_KEY}" \
		-u "elastic:${ELASTIC_PASSWORD}" \
		-X PUT "${ES_URL}/_security/user/logstash_writer" \
		-H 'Content-Type: application/json' \
		-d "{
			\"password\": \"${LOGSTASH_PASSWORD}\",
			\"roles\": [\"logstash_writer\"],
			\"full_name\": \"CORE Logstash ingest user\"
		}"
}

### Main
########################
#
# Run in one of two phases (or "all" for a manual end-to-end run):
#   certs     - generate the CA + certificates (must run before the nodes start)
#   configure - wait for the cluster, then set service-account passwords
#
# The two phases are separate compose services so dependents can wait on them
# with `service_completed_successfully`, which (unlike service_healthy) treats an
# exited one-shot container as satisfied. All operations are idempotent.

cd /usr/share/elasticsearch

PHASE="${1:-all}"

do_certs() {
	generate_ca
	generate_certs
	publish_ca
	secure_permissions
}

do_configure() {
	wait_for_elasticsearch
	set_kibana_password
	create_logstash_user
}

case "${PHASE}" in
	certs)
		log 'CORE setup: certificate phase'
		do_certs
		;;
	configure)
		log 'CORE setup: cluster configuration phase'
		do_configure
		;;
	all)
		log 'CORE setup: full run'
		do_certs
		do_configure
		;;
	*)
		err "Unknown phase '${PHASE}' (expected: certs | configure | all)"
		exit 2
		;;
esac

log 'CORE setup phase complete. Review the output above for any errors.'
