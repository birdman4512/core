#!/usr/bin/env bash

### Variables
########################

set -eu
set -o pipefail

#Generate the address of the cluster (We have also provided defaults)
opensearch_uri="${OPENSEARCH_HOST:-os01}:${OPENSEARCH_PORT:-9200}"

#Directory to place Certificate files
CERT_DIR="/certs" #No trailing /

# User IDs for certificate ownership
OPENSEARCH_UID=1000
FLUENTD_UID=999

#Client Certificate to be generated
clientCertificates=("admin" "os-dashboards" "os01" "os02" "os03" "fluentd" "client")


# --------------------------------------------------------
# Users declarations

declare -A users_passwords
users_passwords=(
	[admin]="${OPENSEARCH_ADMIN_PASS:-}"
)


### Functions
########################

# Log a message.
function log {
	echo "[+] $1"
}

# Log a message at a sub-level.
function sublog {
	echo "   ⠿ $1"
}

# Log an error.
function err {
	echo "[x] $1" >&2
}

# Log an error at a sub-level.
function suberr {
	echo "   ⠍ $1" >&2
}

# Poll the 'opensearch' service until it responds with HTTP code 401.
function wait_for_opensearch {
	
	local -a args=( '-s' '-D-' '-m15' '-w' '%{http_code}' 
		'--cacert' '/usr/share/opensearch/config/certificates/ca/ca.pem'
		"https://${opensearch_uri}/" 
		)

	local -i result=1
	local output
	
	sublog 'Testing Connectivity'
	
	# retry for max 300s (60*5s)
	for _ in $(seq 1 60); do
		local -i exit_code=0
		
		output="$(curl "${args[@]}")" || exit_code=$?
		
		if ((exit_code)); then
			result=$exit_code
		fi

		if [[ "${output: -3}" -eq 401 ]]; then
			sublog 'Opensearch authentication failed. Ready to proceed.'
			result=0
			break
		fi
		
		sublog 'Failed. Trying again in 5 seconds'
		sleep 5
	done
	
	if ((result)) && [[ "${output: -3}" -ne 000 ]]; then
		sublog "Success. Opensearch is ready for the security script"
		echo -e "\n${output::-3}"
	fi

	return $result
}

# Change the password for a user account in Open Search
function change_user_password {
	local username=$1
	local password=$2
	
	local -a args=( '-s' '-D-' '-m15' '-w' '%{http_code}'
		'--cacert' '/usr/share/opensearch/config/certificates/ca/ca.pem'
		'-u' "${username}:admin"
		'-X' 'PUT'
		'-H' 'Content-Type: application/json'
		'-d' "{\"current_password\":\"admin\", \"password\":\"${password}\"}"
		"https://${opensearch_uri}/_plugins/_security/api/account"
		)

	local -i result=1
	local -i exists=0
	local output

	output="$(curl "${args[@]}")"
	if [[ "${output: -3}" -eq 201 ]]; then
		result=0
	fi
	
	if ((result)); then
		echo -e "\n${output::-3}\n"
	fi
	
	#return $result
}


# --------------------------------------------------------

### Script Start
########################


#This part of the script will generate the necessary certificates for the cluster
#It is based off the following pages
# Certificate Generation - https://opensearch.org/docs/latest/security/configuration/generate-certificates/

log 'Certificate Management'
sublog 'Validate certificates ensuring that they are valid and correctly configured to support secure communications within the stack.'

# First, we need to create a certificate authority for the stack. 
recreate_ca=true #By default, we need to create/recreate the CA certificate.


#First up, we need to do one of a few things being either 1) create a new CA certificate, or 2) verify the existing CA certificate that it is healthy.
#To do this, we will first check if the files exist
sublog ''
log 'Certificate Authority' #Print something on screen.
sublog 'Creating CA folders'
mkdir -p ${CERT_DIR}/ca
mkdir -p ${CERT_DIR}/ca-share

sublog 'Setting the permissions on the folder'
chmod 700 ${CERT_DIR}/ca

#Now check if the folder exists
if [ -f ${CERT_DIR}/ca ] &&  [ "$(stat -c '%a' ${CERT_DIR}/ca)" == "700" ];
then
	sublog 'CA Folder created, and permissions applied'
else
	err 'Error creating CA folder or applying permissions.'
fi

#Next, check if already have a set of CA files
if [ -f ${CERT_DIR}/ca/ca.pem ] && [ -f ${CERT_DIR}/ca/ca.key ]; then
	sublog 'CA files exist. Checking certificate validity'
	#Check that the certificate is valid for at least 90 days.
	if openssl x509 -in ${CERT_DIR}/ca/ca.pem -noout -enddate -checkend 7776000 | grep -q "Certificate will not expire"; then
		sublog 'Certificate is valid for the next 90 days, this script will make no further changes.'
		recreate_ca=false
	else
		err 'Identified an issue with certificate, re-issuing.'
		recreate_ca=true
	fi
else 
	err 'Part of the chain is missing. Re-creating'
	recreate_ca=true
fi

## Create CA Certificate.
if [ "$recreate_ca" = true ]; then
	sublog ''
	sublog 'An error has occured with the CA chain, recreating...'
	sublog 'Removing any existing files'
	rm -f ${CERT_DIR}/ca/ca.*
	rm -f ${CERT_DIR}/ca-share/*
	
	sublog 'Generating new certificate and key.'
	openssl genrsa -out ${CERT_DIR}/ca/ca.key $CERT_STRENGTH
	openssl req -new -x509 -sha256 -key ${CERT_DIR}/ca/ca.key -subj $CERT_SN"/CN=root-ca" -out ${CERT_DIR}/ca/ca.pem -days $CERT_DAYS

	sublog 'Setting file permissions.'
	chmod 600 ${CERT_DIR}/ca/ca.key
	chmod 600 ${CERT_DIR}/ca/ca.pem

	chown ${OPENSEARCH_UID}:${OPENSEARCH_UID} -R ${CERT_DIR}/ca

	#Copy the CA certificate to the share folder so other containers can access it.
	cp ${CERT_DIR}/ca/ca.pem ${CERT_DIR}/ca-share/ca.pem
	chmod 777 ${CERT_DIR}/ca-share/ca.pem
fi

# Certificate Generation
for NODE_NAME in "${clientCertificates[@]}"
do	
	recreate_cert=true #By default, we want to create the certifiate.
	sublog ''
	log "Certificate: ${NODE_NAME}"
	sublog 'Creating the folder and setting permissions'
	mkdir -p ${CERT_DIR}/${NODE_NAME}
	chmod 700 ${CERT_DIR}/${NODE_NAME}
	
	if [ -f ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.key ] && [ -f ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.pem ]; then
		sublog 'Certificate exists, checking validity'
	
		#The following should also catch if the CA has been re-created as the chain will fail.
		if output="$(openssl verify -verbose -CAfile ${CERT_DIR}/ca/ca.pem ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.pem)" && [ "$output" == "${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.pem: OK" ]; then
			sublog 'Certificate verified. No further action.'
			recreate_cert=false
		else
			err 'There is an error with the certificate chain, re-creating'
			recreate_cert=true
		fi
	else
		err 'Missing some of the certificate files, or the CA has been re-created. Removing and re-creating'
		recreate_cert=true
	fi

	#Create the certificate
	if [ "$recreate_cert" = true ]; then
		sublog ''
		sublog 'Certificate needs to be created or re-created.'
		sublog 'Removing an existing files' 
		rm -f ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}*
		
		sublog 'Creating certificate...'

		openssl genrsa -out ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}-temp.key $CERT_STRENGTH
		openssl pkcs8 -inform PEM -outform PEM -in ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}-temp.key -topk8 -nocrypt -v1 PBE-SHA1-3DES -out ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.key	
		openssl req -new -key ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.key -subj $CERT_SN"/CN="${NODE_NAME} -out ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.csr
		echo 'subjectAltName=DNS:'${NODE_NAME}',DNS:'${NODE_NAME}'.'${CERT_DN} > ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.ext
		openssl x509 -req -in ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.csr -CA ${CERT_DIR}/ca/ca.pem -CAkey ${CERT_DIR}/ca/ca.key -CAcreateserial -sha256 -out ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.pem -days $CERT_DAYS -extfile ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}.ext
		rm "${CERT_DIR}/$NODE_NAME/$NODE_NAME-temp.key" "${CERT_DIR}/$NODE_NAME/$NODE_NAME.csr"

		sublog 'Setting certificate permissions.'
		chmod 777 ${CERT_DIR}/${NODE_NAME}/${NODE_NAME}*

		if [ "$NODE_NAME" = "fluentd" ]; then
			chown ${FLUENTD_UID}:${FLUENTD_UID} -R ${CERT_DIR}/${NODE_NAME}
		else
			chown ${OPENSEARCH_UID}:${OPENSEARCH_UID} -R ${CERT_DIR}/${NODE_NAME}
		fi
	fi
done

sublog ''
#Next, we only want to run the OpenSearch configuration once. So lets put a file down when it runs successfully.
log "Setting up OpenSearch Security..."
if ! [ -f ${CERT_DIR}/setup_opensearch.txt ]; then 
	sublog ''
	sublog 'Waiting for availability of Opensearch. This can take several minutes.'

	declare -i exit_code=0
	wait_for_opensearch || exit_code=$?

	if ((exit_code)); then
		sublog $exit_code
		case $exit_code in
			6)
				suberr 'Could not resolve host. Is Opensearch running?'
				;;
			7)
				suberr 'Failed to connect to host. Is Opensearch healthy?'
				;;
			28)
				suberr 'Timeout connecting to host. Is Opensearch healthy?'
				;;
			*)
				suberr "Connection to Opensearch failed. Exit code: ${exit_code}"
				;;
		esac

		exit $exit_code
	fi

	sublog 'Opensearch is running'

	log 'Running the security setup script'

	chmod +x /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh && \
	bash /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh -cd /usr/share/opensearch/config/opensearch-security -icl -nhnv -cacert /usr/share/opensearch/config/certificates/ca/ca.pem -cert /usr/share/opensearch/config/certificates/admin/admin.pem -key /usr/share/opensearch/config/certificates/admin/admin.key -h ${OPENSEARCH_HOST:-os01}
	
	echo "opensearch_setup" > ${CERT_DIR}/setup_opensearch.txt
else
	sublog "Opensearch previously setup. run a 'docker-compose down && docker-compose up -d' for new certificates to take effect"
fi

#Check if the user accounts have been previously setup.
if ! [ -f ${CERT_DIR}/setup_users.txt ]; then 
	sublog ''
	sublog ''
	
	#Work through each of the user accounts updating their password.
	log 'Updating user account passwords.'
	for user in "${!users_passwords[@]}"; 
	do
		sublog "User: '$user'"
		
		if [[ -z "${users_passwords[$user]:-}" ]]; then
			err 'No password defined, skipping'
			continue
		fi

		sublog ''
		change_user_password "$user" "${users_passwords[$user]}"
	done
	
	echo "users_setup" > ${CERT_DIR}/setup_users.txt
	
else
	sublog "User accounts previously updated"

fi

sublog ""
sublog ""
log "Setup complete, review output for possible errors"