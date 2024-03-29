#!/bin/bash
set -e

export SCRIPTNAME="$0"
export SCRIPTDIR=$(cd $(dirname $0) && pwd)

DEBUG=0
LOGFILE="$SCRIPTDIR/$0.log"

if [[ $# -lt 4 ]] ; then
        echo "usage: $0 IaaS domain environment pivnet-token"
        echo ""
        echo "where:"
        echo "     IaaS: is one of {gcp | aws | azure | vsphere}"
        echo "     domain: the parent domain from which the PCF subdomains and wildcards will originate"
        echo "     environment: the short name for the environment that will be the subdomain for PCF"
        echo "     	Example:  domain=example.com & environment=test results in pcf.test.example.com"
        echo "     pivnet-token: the LEGACY API TOKEN [DEPRECATED] from your user profile on network.pivotal.io"
        echo ""
        exit 1
fi

#OM_IAAS="$(askUser "Please pick a target IAAS: gcp, aws, azure, or vsphere? ")"
OM_IAAS="$1"
OM_DOMAIN_NAME="$2"
#OM_ENV_NAME="$(askUser "Decide on a short subdomain name (like \"pcf\") for the environment? ")"
OM_ENV_NAME="$3"
#PIVNET_API_TOKEN="iigMJxjc3wkqxRiknHR1"
PIVNET_API_TOKEN="$4"

# TODO set these dynamically
OM_ADMIN_USERNAME="admin"

OM_STATE_DIRECTORY="$PWD/state/$OM_IAAS/$OM_ENV_NAME"
mkdir -p "$OM_STATE_DIRECTORY"

OM_ENVIRONMENT_VARS="$OM_STATE_DIRECTORY/$OM_ENV_NAME.envrc"
#if [[ -f "${OM_ENVIRONMENT_VARS}" ]]; then
#    source "${OM_ENVIRONMENT_VARS}"
#fi


# getting om from pivotal's github
OM_BIN="${OM_STATE_DIRECTORY}/om-linux-3.1.0"
if [[ ! -f "$OM_BIN" ]]; then
	wget --directory-prefix=${OM_STATE_DIRECTORY} https://github.com/pivotal-cf/om/releases/download/3.1.0/om-linux-3.1.0
	chmod +x $OM_BIN
fi

TERRAFORM_BIN="${OM_STATE_DIRECTORY}/terraform"
if [[ ! -f "$TERRAFORM_BIN" ]]; then
	wget --directory-prefix=${OM_STATE_DIRECTORY} https://releases.hashicorp.com/terraform/0.11.14/terraform_0.11.14_linux_amd64.zip
	unzip -d ${OM_STATE_DIRECTORY} ${OM_STATE_DIRECTORY}/terraform_0.11.14_linux_amd64.zip
	chmod +x $TERRAFORM_BIN
fi

OM_CERT_PRIV_KEY="${OM_STATE_DIRECTORY}/${OM_DOMAIN_NAME}.key"
OM_CERT="${OM_STATE_DIRECTORY}/${OM_DOMAIN_NAME}.cert"
OM_CERT_CONFIG="${OM_STATE_DIRECTORY}/${OM_DOMAIN_NAME}.cnf"


# --------------------------------------------------
# Output standard formatted logging to LOGFILE
# usage: log LOGFILE "message"
# --------------------------------------------------
function log() 
{
	[ $# -gt 1 ] || { echo "Function log() too few arguments.  need filename and message string" && exit 1; }
	LOGFILE="${1}" 
	shift
	touch "${LOGFILE}" || { echo "Log file \"${LOGFILE}\" is not writeable" && exit 1; }

	message="$@"
	script_name=${0##*/}
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	echo "== ${script_name} ${timestamp} ${message}" >> "${LOGFILE}"
}

# --------------------------------------------------
# A little function to ask a user for input
# always returns 0, but echo's the user's sanitized response for capture as a string by the caller
# --------------------------------------------------
function askUser() {
	read -p "$1: " __val
	# first, strip underscores
	CLEAN=${__val//_/}
	# next, replace spaces with underscores
	CLEAN=${CLEAN// /_}
	# now, clean out anything that's not alphanumeric or an underscore or a hyphen
	CLEAN=${CLEAN//[^a-zA-Z0-9_-]/}
	echo "${CLEAN}"

	return 0
}

# --------------------------------------------------
# A little more function based on askUser() to specifically ask a yes or no question
# returns 0 for Yes or 1 for "not yes"
# --------------------------------------------------
function askYes() {
	ANSWER="$(askUser "$1 (Y|y) ")"
	if [ "$ANSWER" == "${ANSWER#[Yy]}" ]; then
		return 1
	else
		return 0
	fi
}	


# --------------------------------------------------
# Ask a user for input specifying a default value
# usage: assume "default_value" "question"
# --------------------------------------------------
function assume() 
{
	[ $# -eq 2 ] || { echo "Function assume() not enough arguments. need dafault answer and question string" && exit 1; }
	DEFAULT="${1}" 
	shift
	QUESTION="$@"

	read -p "${QUESTION} [ENTER] for [${DEFAULT}] " __val
	[ "x${__val}x" = "xx" ] && __val="${DEFAULT}"

        # first, strip underscores
        CLEAN=${__val//_/}
        # next, replace spaces with underscores
        CLEAN=${CLEAN// /_}
        # now, clean out anything that's not alphanumeric or an underscore or a hyphen
        CLEAN=${CLEAN//[^a-zA-Z0-9_-]/}
        echo "${CLEAN}"

        return 0
}

# --------------------------------------------------
# Create a new GCP service account and set relevant GCP environment variables
# Requires: the command gcloud in the path
# --------------------------------------------------
function gcpInitialize() {
if [[ $# -lt 3 ]] ; then
        echo "Usage: $0 OM_ENV_NAME OM_STATE_DIRECTORY OM_ENVIRONMENT_VARS"
        echo ""
        exit 1
fi

OM_ENV_NAME="${1}"
OM_STATE_DIRECTORY="${2}"
OM_ENVIRONMENT_VARS="${3}"
OM_IAAS="gcp"

if [[ -r ${OM_ENVIRONMENT_VARS} ]]; then source ${OM_ENVIRONMENT_VARS}; fi

gcloud -v >/dev/null 2>&1 || { echo "gcloud command required in path" && exit 1; }

# ---- set GCP_PROJECT ----
RESETVAR=true # assume we're going to reset the var
if [[ ! -z ${GCP_PROJECT+x} ]]; then # if it is already set to something
	askYes "Your GCP Project ID is set to $GCP_PROJECT_ID.  Keep it?"; RESP=$?
	if [[ $RETVAL -eq 0 ]]; then RESETVAR=false; fi # don't reset it
fi
if [[ $RESETVAR = true ]]; then
	echo ""; echo "Determining your GCP Project ID with gcloud projects list"
	GCP_PROJECTS="`gcloud projects list | grep -v "PROJECT_NUMBER" | awk '{print $1}'`"
	if [[ `echo $GCP_PROJECTS | wc -w` == "1" ]]; then
		GCP_PROJECT_ID=$GCP_PROJECTS
		echo "Since you only have access to a single GCP project, using ${GCP_PROJECT_ID} for this deployment"
	else
		echo "You have access to these GCP projects:"
		echo "$GCP_PROJECTS"
		GCP_PROJECT_ID="$(askUser "Please enter one of the above GCP Project ID's for this deployment")"
	fi
fi

# ---- set GCP_SERVICE_ACCOUNT ----
RESETVAR=true
if [[ ! -z ${GCP_SERVICE_ACCOUNT_NAME+x} ]]; then 
        askYes "Your GCP Service Account Name is set to $GCP_SERVICE_ACCOUNT_NAME.  Keep it?"; RETVAL=$?
        if [[ $RETVAL -eq 0 ]]; then RESETVAR=false; fi # don't reset it
fi
if [[ $RESETVAR = true ]]; then
	echo ""; echo "Creating a new service account in GCP that will own the deployment"
	GCP_SERVICE_ACCOUNT_NAME="`echo $OM_ENV_NAME | awk '{print tolower($0)}'`""serviceaccount"
	GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
	echo "Checking to see if $GCP_SERVICE_ACCOUNT_NAME already exists"
	gcloud iam service-accounts describe "${GCP_SERVICE_ACCOUNT}" > /dev/null 2>&1; RETVAL=$?
	if [[ $RETVAL -eq 0 ]]; then
		echo "Service Account $GCP_SERVICE_ACCOUNT_NAME already exists.  Nothing to do."
	else
		echo "$ gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME"
		gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME
		RETVAL=$?
		if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you are having issues with permissions."; exit 1; fi
	fi

	GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

	sleep 1; echo ""; echo "Creating a new service account key. I will store it here:"
	GCP_SERVICE_ACCOUNT_KEY="$OM_STATE_DIRECTORY/terraform.key.json"
	echo "$GCP_SERVICE_ACCOUNT_KEY"
	touch $GCP_SERVICE_ACCOUNT_KEY;  chmod 700 $GCP_SERVICE_ACCOUNT_KEY
	echo "$ gcloud iam service-accounts keys create --iam-account=\"${GCP_SERVICE_ACCOUNT}\" $GCP_SERVICE_ACCOUNT_KEY"
	gcloud iam service-accounts keys create --iam-account="${GCP_SERVICE_ACCOUNT}" $GCP_SERVICE_ACCOUNT_KEY
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi


	sleep 1; echo ""; echo "Binding the service account to the project with owner role"
	echo "gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=\"serviceAccount:${GCP_SERVICE_ACCOUNT}\" --role='roles/owner'"
	gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${GCP_SERVICE_ACCOUNT}" --role='roles/owner'
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you are having issues with permissions."; exit 1; fi

fi

# ---- set GCP_REGION ----
RESETVAR=true
if [[ ! -z ${GCP_REGION+x} ]]; then 
        askYes "Your GCP Region is set to $GCP_REGION.  Keep it?"; RETVAL=$?
        if [[ $RETVAL -eq 0 ]]; then RESETVAR=false; fi # don't reset it
fi
if [[ $RESETVAR = true ]]; then
	sleep 1; echo ""; echo "Here is a list of regions where BOSH can be deployed"
	echo "$ gcloud compute regions list"
	gcloud compute regions list
	GCP_REGION="$(askUser "Please input the name of one of these regions for the deployment")"

	sleep 1; echo ""; echo "Here is a list of zones for that region"
	echo "$ gcloud compute zones list | grep ${GCP_REGION}"
	i=0
	for args in `gcloud compute zones list | grep ${GCP_REGION} | awk '{print $1}'`
	do
		ZONES[i]=$args
		echo $args
		i=$i+1
	done 

	GCP_AZ1="${ZONES[0]}"
	GCP_AZ2="${ZONES[1]}"
	GCP_AZ3="${ZONES[2]}"

	GCP_AZ1="$(assume $GCP_AZ1 "Please input the name of the 1st AZ of 3")"
	GCP_AZ2="$(assume $GCP_AZ2  "Please input the name of the 2nd AZ of 3")"
	GCP_AZ3="$(assume $GCP_AZ3  "Please input the name of the 3rd AZ of 3")"
fi

echo ""; echo "Here are the environment variables for $OM_IAAS:"
echo ""
{
echo "export OM_IAAS=$OM_IAAS"
echo "export OM_ENV_NAME=$OM_ENV_NAME"
echo "export OM_STATE_DIRECTORY=$OM_STATE_DIRECTORY"
echo "export GCP_REGION=$GCP_REGION"
echo "export GCP_AZ1=$GCP_AZ1"
echo "export GCP_AZ2=$GCP_AZ2"
echo "export GCP_AZ3=$GCP_AZ3"
echo "export GCP_PROJECT_ID=$GCP_PROJECT_ID"
echo "export GCP_SERVICE_ACCOUNT_NAME=$GCP_SERVICE_ACCOUNT_NAME"
echo "export GCP_SERVICE_ACCOUNT=$GCP_SERVICE_ACCOUNT"
echo "export GCP_SERVICE_ACCOUNT_KEY=$GCP_SERVICE_ACCOUNT_KEY"
} | tee $OM_ENVIRONMENT_VARS
}
#######################

# --------------------------------------------------
function omDeploy()
{

	echo "Downloading Terraform templates from Pivnet to pave $OM_IAAS"
	PIVNET_FILE_GLOB="terraforming-${OM_IAAS}*zip"
	PIVNET_PRODUCT_SLUG="elastic-runtime"
	PIVNET_PRODUCT_VERSION="2.6.3"
	WORKSPACE_DIRECTORY="${OM_STATE_DIRECTORY}"

	cd $WORKSPACE_DIRECTORY

	if [[ ! -f ${PIVNET_FILE_GLOB} ]]; then
		$OM_BIN download-product --pivnet-api-token ${PIVNET_API_TOKEN} --pivnet-file-glob "${PIVNET_FILE_GLOB}" --pivnet-product-slug ${PIVNET_PRODUCT_SLUG} --product-version ${PIVNET_PRODUCT_VERSION} --output-directory "${WORKSPACE_DIRECTORY}" 

		unzip ${PIVNET_FILE_GLOB}
	fi
	cd pivotal-cf-terraforming-*/terraforming-pks
	echo "now sitting in $PWD"
	# downloading ops manager yml to parse location of oms-mgr image in azure
	# $OM_BIN download-product --pivnet-api-token iigMJxjc3wkqxRiknHR1 --pivnet-file-glob "ops-manager-azure*yml" --pivnet-product-slug ops-manager --product-version 2.6.5 --output-directory .

if [ $OM_IAAS == "gcp" ]; then
	echo "GCP section, just before CAT"
	cat <<EOT > terraform.tfvars
env_name         = "$OM_ENV_NAME"
opsman_image_url = "ops-manager-us/pcf-gcp-2.6.6-build.179.tar.gz"
region           = "$GCP_REGION"
zones            = ["${GCP_AZ1}", "${GCP_AZ2}", "${GCP_AZ3}"]
project          = "${GCP_PROJECT_ID}"
dns_suffix       = "${OM_DOMAIN_NAME}"

ssl_cert = <<SSL_CERT
`cat $OM_CERT`
SSL_CERT

ssl_private_key = <<SSL_KEY
`cat $OM_CERT_PRIV_KEY`
SSL_KEY

service_account_key = <<SERVICE_ACCOUNT_KEY
`cat $GCP_SERVICE_ACCOUNT_KEY`
SERVICE_ACCOUNT_KEY

EOT

elif [ $OM_IAAS == "aws" ]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [ $OM_IAAS == "vsphere" ]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [ $OM_IAAS == "azure" ]; then

	cat <<EOT > terraform.tfvars
subscription_id       = "$OM_AZURE_SUBSCRIPTION_ID"
tenant_id             = "$OM_AZURE_TENANT_ID"
client_id             = "$OM_AZURE_CLIENT_ID"
client_secret         = "$OM_AZURE_CLIENT_SECRET"

env_name              = "$OM_ENV_NAME"
env_short_name        = "$OM_ENV_NAME"
location              = "$OM_AZURE_REGION"
ops_manager_image_uri = "https://opsmanagereastus.blob.core.windows.net/images/ops-manager-2.6.5-build.173.vhd"
dns_suffix            = "$OM_DOMAIN_NAME"
vm_admin_username     = "$OM_ADMIN_USERNAME"
EOT

else
	echo "${OM_IAAS} is not a valid selection.  Exiting!"
	exit 1
fi
	
	$TERRAFORM_BIN init
	$TERRAFORM_BIN plan -out=plan
	$TERRAFORM_BIN apply plan
}

# --------------------------------------------------
function gcpConfigure()
{
	OM_CONFIG_TEMPLATE="${SCRIPTDIR}/configs/opsmgr-gcp-2.6.6-build.179.template"
	OM_CONFIG_FILE="${OM_STATE_DIRECTORY}/om-director-config.yml"
	OM_ADMIN_USER="admin"
	OM_ADMIN_PASSWORD="keepitsimple"
	OM_ADMIN_DECRYPT_PASSPHRASE="keepitsimple"
	
	nslookup pcf.$OM_ENV_NAME.$OM_DOMAIN_NAME > /dev/null 2>&1; RETVAL=$?

	while [[ ! $RETVAL -eq 0 ]]; do
		echo "pcf.$OM_ENV_NAME.$OM_DOMAIN_NAME not found."
		echo "You need to create an NS record for $OM_ENV_NAME on ${OM_DOMAIN_NAME} pointing to these nameservers:"
		$TERRAFORM_BIN output env_dns_zone_name_servers

		askYes "Try pcf.$OM_ENV_NAME.$OM_DOMAIN_NAME again?"; RESP=$?
		if [[ ! $RESP -eq 0 ]]; then echo "Ok.  Exiting."; exit 1; fi
		nslookup pcf.$OM_ENV_NAME.$OM_DOMAIN_NAME > /dev/null 2>&1; RETVAL=$?
	done
	cat $OM_CONFIG_TEMPLATE | envsubst > $OM_CONFIG_FILE
	
	$OM_BIN -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k configure-authentication \
		--username ${OM_ADMIN_USER} --password ${OM_ADMIN_PASSWORD} \
		--decryption-passphrase ${OM_ADMIN_DECRYPT_PASSPHRASE}

#	## gcp config page
#	terraform output project_id
#
#	# director config
#	 time.google.com
#	 enable VM resurrector plugin
#        # enable post deploy scripts
#        # recreate all VM's
#
#        ## create availability zones
#	terraform output azs
#	terraform output azs[0]
#
#        ## create networks page
#        # network name = infrastructure
#        TF_OUT_NETWORK="`terraform output network_name`"
#        TF_OUT_INFRA_SUBNET="`terraform output infrastructure_subnet_name`"
#	TF_OUT_REGION="`terraform output region`"
#        echo "${TF_OUT_NETWORK}/${TF_OUT_INFRA_SUBNET}/${TF_OUT_REGION}"
#        terraform output infrastructure_subnet_cidrs
#        # dns = 168.63.129.16
#        terraform output infrastructure_subnet_gateway
#
#        # network name = pks
#        terraform output network_name
#        TF_OUT_PKS_SUBNET="`terraform output pks_subnet_name`"
#        echo "${TF_OUT_NETWORK}/${TF_OUT_PKS_SUBNET}/${TF_OUT_REGION}"
#        terraform output pks_subnet_name
#        terraform output pks_subnet_cidrs
#        # dns = 168.63.129.16
#        terraform output pks_subnet_gateway
#
#        # network name = services
#        terraform output network_name
#        TF_OUT_SERVICES_SUBNET="`terraform output services_subnet_name`"
#        echo "${TF_OUT_NETWORK}/${TF_OUT_SERVICES_SUBNET}/${TF_OUT_REGION}"
#        terraform output services_subnet_name
#        terraform output services_subnet_cidrs
#        # dns = 168.63.129.16
#        terraform output services_subnet_gateway
#
#        ## Assign AZs and Networks
#        # Singleton AZ = zone-1
#        # Network = infrastructure
#
#        ## Security
#        # generate passwords
#
	OM_CONFIG_YML="configs/opsmgr-gcp-2.6.6-build.179.yml"
#	## generate configuration YML from running ops manager
#	$OM_BIN -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k \
#		-u ${OM_ADMIN_USER} -p ${OM_ADMIN_PASSWORD} \
#		staged-director-config --no-redact > ${OM_CONFIG_YML}

	## configure director using YML file
	$OM_BIN -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k \
		-u ${OM_ADMIN_USER} -p ${OM_ADMIN_PASSWORD} \
		configure-director --config ${OM_CONFIG_FILE}

	$OM_BIN -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k \
		-u ${OM_ADMIN_USER} -p ${OM_ADMIN_PASSWORD} \
		apply-changes

}

source $OM_ENVIRONMENT_VARS
if [[ $OM_IAAS == "gcp" ]]; then
	gcpInitialize "${OM_ENV_NAME}" "${OM_STATE_DIRECTORY}" "${OM_ENVIRONMENT_VARS}"
	sleep 1; echo ""; echo "Creating a self signed certificate for use in the deployment"
	${SCRIPTDIR}/commands/createCert.sh "${OM_DOMAIN_NAME}" "${OM_CERT_PRIV_KEY}" "${OM_CERT}" "${OM_CERT_CONFIG}" 
	omDeploy
	gcpConfigure
elif [[ $OM_IAAS == "aws" ]]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [[ $OM_IAAS == "vsphere" ]]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [[ $OM_IAAS == "azure" ]]; then
	azureInitialize
	omDeploy
	azureConfigure
else
	echo "${OM_IAAS} is not a valid selection.  Exiting!"
	exit 1
fi

