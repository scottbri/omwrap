#!/bin/bash

DEBUG=0
DEBUGFILE="initialize_iaas.log"

# A little function to ask a user for input
# always returns 0, but echo's the user's sanitized response for capture as a string by the caller
askUser() {
	read -p "$1"": " __val
	# first, strip underscores
	CLEAN=${__val//_/}
	# next, replace spaces with underscores
	CLEAN=${CLEAN// /_}
	# now, clean out anything that's not alphanumeric or an underscore or a hyphen
	CLEAN=${CLEAN//[^a-zA-Z0-9_-]/}
	echo "${CLEAN}"

	return 0
}

# A little more function based on askUser() to specifically ask a yes or no question
# returns 0 for Yes or 1 for "not yes"
askYes() {
	CLEAN="$(askUser "$1 (Y|y) ")"
	if [ "$CLEAN" == "${CLEAN#[Yy]}" ]; then
		return 1
	else
		return 0
	fi
}	

# TODO set these dynamically
PIVNET_API_TOKEN="iigMJxjc3wkqxRiknHR1"
OM_ADMIN_USERNAME="admin"

OM_IAAS="$(askUser "Please pick a target IAAS: gcp, aws, azure, or vsphere? ")"
OM_DOMAIN_NAME="${OM_IAAS}.harnessingunicorns.io"
OM_ENV_NAME="$(askUser "Decide on a short subdomain name (like \"pcf\") for the environment? ")"
OM_STATE_DIRECTORY="$PWD/state/$OM_IAAS/$OM_ENV_NAME"
OM_ENVIRONMENT_VARS="$OM_STATE_DIRECTORY/$OM_ENV_NAME.envrc"
if [[ -f "${OM_ENVIRONMENT_VARS}" ]]; then
    source "${OM_ENVIRONMENT_VARS}"
fi

mkdir -p "$OM_STATE_DIRECTORY"

OM_CERT_PRIV_KEY="${OM_STATE_DIRECTORY}/${PCF_DOMAIN_NAME}.key"
OM_CERT="${OM_STATE_DIRECTORY}/${PCF_DOMAIN_NAME}.cert"
OM_CERT_CONFIG="${OM_STATE_DIRECTORY}/${PCF_DOMAIN_NAME}.cnf"
# Create a PCF wildcard certificate based on a domain name passed as an argument 
# Requires: openssl in the path
function createCert()
{
	PCF_DOMAIN_NAME=${1}
	cat > ${OM_CERT_CONFIG} <<-EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C=US
ST=California
L=San Francisco
O=PIVOTAL, INC.
OU=Workshops
CN = ${PCF_DOMAIN_NAME}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.sys.${PCF_DOMAIN_NAME}
DNS.2 = *.login.sys.${PCF_DOMAIN_NAME}
DNS.3 = *.uaa.sys.${PCF_DOMAIN_NAME}
DNS.4 = *.apps.${PCF_DOMAIN_NAME}
DNS.5 = *.pks.${PCF_DOMAIN_NAME}
EOF

openssl req -x509 \
  -newkey rsa:2048 \
  -nodes \
  -keyout ${OM_CERT_PRIV_KEY} \
  -out ${OM_CERT} \
  -config ${OM_CERT_CONFIG}

}

function gcpInitialize()
{
	OM_GCP_SERVICE_ACCOUNT_KEY="${OM_GCP_SERVICE_ACCOUNT_KEY:-UNSET}"
	OM_GCP_REGION="${OM_GCP_REGION:-UNSET}"
	
	echo "Here are how the required environment variables to bbl up on $OM_IAAS are currently set:"
	echo "OM_IAAS=$OM_IAAS"
	echo "OM_ENV_NAME=$OM_ENV_NAME"
	echo "OM_GCP_REGION=$OM_GCP_REGION"
	echo "OM_GCP_SERVICE_ACCOUNT_KEY=$OM_GCP_SERVICE_ACCOUNT_KEY"
	echo "OM_STATE_DIRECTORY=$OM_STATE_DIRECTORY"
		
	echo ""; askYes "Would you like to continue and get help populating these values?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Ok then.  Good luck bbl-ing up on $OM_IAAS!"; return ${RETVAL}; fi

	sleep 1; echo ""; echo "Great!  Let's continue."
	echo ""; echo "Let's determine your GCP Project ID"
	echo "gcloud projects list"
	GCP_PROJECTS="`gcloud projects list | grep -v "PROJECT_NUMBER" | awk '{print $1}'`"
	if [ `echo $GCP_PROJECTS | wc -w` == "1" ]; then
		GCP_PROJECT_ID=$GCP_PROJECTS
		echo "Since you only have access to a single GCP project.  We'll use it for this deployment"
		echo "GCP_PROJECT_ID=$GCP_PROJECT_ID"
	else
		echo "You seem to have access to these GCP projects:"
		echo "$GCP_PROJECTS"
		GCP_PROJECT_ID="$(askUser "Please enter one of the above GCP Project ID's for this deployment")"
	fi

	echo ""; echo "Creating a new service account in GCP that will own the BOSH deployment"
	GCP_SERVICE_ACCOUNT_NAME="`echo $OM_ENV_NAME | awk '{print tolower($0)}'`""serviceaccount"
	echo "$ gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME"
	gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi
	
	sleep 1; echo ""; echo "Now I need to create a service account key. I'll store it here:"
	OM_GCP_SERVICE_ACCOUNT_KEY="$OM_STATE_DIRECTORY/terraform.key.json"
	echo "$OM_GCP_SERVICE_ACCOUNT_KEY"
	touch $OM_GCP_SERVICE_ACCOUNT_KEY;  chmod 700 $OM_GCP_SERVICE_ACCOUNT_KEY
	echo "$ gcloud iam service-accounts keys create --iam-account=\"${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com\" $OM_GCP_SERVICE_ACCOUNT_KEY"
	askYes "Are you good with me issuing the above command?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	gcloud iam service-accounts keys create --iam-account="${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" $OM_GCP_SERVICE_ACCOUNT_KEY
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi


	sleep 1; echo ""; echo "Binding the service account to the project with owner role"
	echo "gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=\"serviceAccount:${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com\" --role='roles/owner'"
	askYes "Are you good with me issuing the above command?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" --role='roles/owner'
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi

	sleep 1; echo ""; echo "Here is a list of regions where BOSH can be deployed"
	echo "$ gcloud compute regions list"
	gcloud compute regions list
	OM_GCP_REGION="$(askUser "Please input the name of one of these regions for the deployment")"


	echo ""; echo "Here are the environment variables you need to set to deploy BOSH on $OM_IAAS:"
	echo ""
	{
	echo "export OM_IAAS=$OM_IAAS"
	echo "export OM_ENV_NAME=$OM_ENV_NAME"
	echo "export OM_STATE_DIRECTORY=$OM_STATE_DIRECTORY"
	echo "export OM_GCP_REGION=$OM_GCP_REGION"
	echo "export OM_GCP_SERVICE_ACCOUNT_KEY=$OM_GCP_SERVICE_ACCOUNT_KEY"
	echo "export GCP_PROJECT_ID=$GCP_PROJECT_ID"
	echo "export GCP_SERVICE_ACCOUNT_NAME=$GCP_SERVICE_ACCOUNT_NAME"
	} | tee $OM_ENVIRONMENT_VARS
}

function azureInitialize()
{
	OM_AZURE_REGION="${OM_AZURE_REGION:-UNSET}"
	OM_AZURE_SUBSCRIPTION_ID="${OM_AZURE_SUBSCRIPTION_ID:-UNSET}"
	OM_AZURE_TENANT_ID="${OM_AZURE_TENANT_ID:-UNSET}"
	OM_AZURE_CLIENT_ID="${OM_AZURE_CLIENT_ID:-UNSET}"
	OM_AZURE_CLIENT_SECRET="${OM_AZURE_CLIENT_SECRET:-UNSET}"
	
	echo "Here are how the required environment variables to bbl up on $OM_IAAS are currently set:"
	echo "OM_IAAS=$OM_IAAS"
	echo "OM_ENV_NAME=$OM_ENV_NAME"
	echo "OM_AZURE_REGION=$OM_AZURE_REGION"
	echo "OM_AZURE_SUBSCRIPTION_ID=$OM_AZURE_SUBSCRIPTION_ID"
	echo "OM_AZURE_TENANT_ID=$OM_AZURE_TENANT_ID"
	echo "OM_AZURE_CLIENT_ID=$OM_AZURE_CLIENT_ID"
	echo "OM_AZURE_CLIENT_SECRET=$OM_AZURE_CLIENT_SECRET"
	echo "OM_STATE_DIRECTORY=$OM_STATE_DIRECTORY"
		
	echo ""; askYes "Would you like to continue and get help populating these values?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Ok then.  Good luck bbl-ing up on $OM_IAAS!"; return $RETVAL; fi

	sleep 1; echo ""; echo "Great!  Let's continue."
	OM_AZURE_CLIENT_SECRET="$(askUser "Please enter a complex secret alphanumeric password for your new Active Directory application")"
		
	sleep 1; echo "Thanks!  Now we'll make sure you're logged into Azure.  Please follow the prompts to login:"
	echo "=========="
	echo '$ az login'
	az login 2>&1
	sleep 1; echo ""; echo "=========="; echo "... and we're back"

	sleep 1; echo ""; echo "Here is a list of locations (regions) where BOSH can be deployed"
	echo '$ az account list-locations | jq -r .[].name'
	az account list-locations | jq -r .[].name
	OM_AZURE_REGION="$(askUser "Please input the name of one of these regions for the deployment")"

	sleep 1; echo ""; echo "I'm querying Azure for your default Subscription ID and Tenant ID"
	echo '$ az account list --all'
	AZ_ACCOUNT_LIST="`az account list --all`"
	export OM_AZURE_SUBSCRIPTION_ID="`echo \"$AZ_ACCOUNT_LIST\" | jq -r '.[] | select(.isDefault) | .id'`"
	echo "Your OM_AZURE_SUBSCRIPTION_ID is $OM_AZURE_SUBSCRIPTION_ID:"

	export OM_AZURE_TENANT_ID="`echo \"$AZ_ACCOUNT_LIST\" | jq -r '.[] | select(.isDefault) | .tenantId'`"
	echo "Your OM_AZURE_TENANT_ID is $OM_AZURE_TENANT_ID"
	if [ $DEBUG ]; then echo "$AZ_ACCOUNT_LIST" >> $DEBUGFILE; fi
	

	AZURE_SP_DISPLAY_NAME="Service Principal for BOSH"
	AZURE_SP_HOMEPAGE="http://BOSHAzureCPI"
	AZURE_SP_IDENTIFIER_URI="http://BOSHAzureCPI-$RANDOM"
	AZURE_OUTPUTFILE_JSON="service-principal.json"

	echo ""; echo "Creating an Active Directory application to generate a new Application ID"
	echo "$ az ad app create --display-name \"$AZURE_SP_DISPLAY_NAME\" \\"
	echo "	--password \"$OM_AZURE_CLIENT_SECRET\" --homepage \"$AZURE_SP_HOMEPAGE\" \\"
	echo "	--identifier-uris \"$AZURE_SP_IDENTIFIER_URI\""
	askYes "Are you good with me issuing the above command?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	AZ_AD_APP_CREATE="`az ad app create --display-name \"$AZURE_SP_DISPLAY_NAME\" \
		--password \"$OM_AZURE_CLIENT_SECRET\" --homepage \"$AZURE_SP_HOMEPAGE\" \
		--identifier-uris \"$AZURE_SP_IDENTIFIER_URI\"`"
	export OM_AZURE_CLIENT_ID="`echo \"$AZ_AD_APP_CREATE\" | jq -r '.appId'`"
	echo "Your OM_AZURE_CLIENT_ID is $OM_AZURE_CLIENT_ID"
	if [ $DEBUG ]; then echo "$AZ_AD_APP_CREATE" >> $DEBUGFILE; fi

	echo ""; echo "Creating the Service Principal corresponding to the new Application"
	echo "$ az ad sp create --id $OM_AZURE_CLIENT_ID"
	askYes "Are you good with me issuing the above command?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	AZ_AD_SP_CREATE="`az ad sp create --id $OM_AZURE_CLIENT_ID`"
	if [ $DEBUG ]; then echo "$AZ_AD_SP_CREATE" >> $DEBUGFILE; fi

	echo ""; echo "Sleeping 45 seconds to let Azure AD catch up before proceeding"
	sleep 45
	echo ""; echo "Assigning the Service Principal to the Owner Role"
	echo "$ az role assignment create --assignee $OM_AZURE_CLIENT_ID --role Owner --scope /subscriptions/$OM_AZURE_SUBSCRIPTION_ID"
	askYes "Are you good with me issuing the above command?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	AZ_ROLE_ASSIGNMENT_CREATE="`az role assignment create --assignee $OM_AZURE_CLIENT_ID --role Owner --scope /subscriptions/$OM_AZURE_SUBSCRIPTION_ID`"
	if [ $DEBUG ]; then echo "$AZ_ROLE_ASSIGNMENT_CREATE" >> $DEBUGFILE; fi

	echo ""; echo "Registering the Subscription with Microsoft Storage, Network, and Compute"
	echo "$ az provider register --namespace Microsoft.Storage"
	echo "$ az provider register --namespace Microsoft.Network"
	echo "$ az provider register --namespace Microsoft.Compute"
	askYes "Are you good with me issuing the above three (3) commands?"; RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Bailing out now!  Good luck bbl-ing up on $OM_IAAS!"; exit 1; fi
	az provider register --namespace Microsoft.Storage
	az provider register --namespace Microsoft.Network
	az provider register --namespace Microsoft.Compute
	
	echo "Finished!  Here are the environment variables you need to set for bbl to deploy BOSH on Azure:"
	echo "Copy and paste them into your shell (or .envrc) and then run bbl .  Also, archive these for posterity!"
	echo ""
	{
	echo "export OM_IAAS=$OM_IAAS"
	echo "export OM_ENV_NAME=$OM_ENV_NAME"
	echo "export OM_STATE_DIRECTORY=$OM_STATE_DIRECTORY"
	echo "export OM_AZURE_REGION=$OM_AZURE_REGION"
	echo "export OM_AZURE_SUBSCRIPTION_ID=$OM_AZURE_SUBSCRIPTION_ID"
	echo "export OM_AZURE_TENANT_ID=$OM_AZURE_TENANT_ID"
	echo "export OM_AZURE_APPLICATION_ID=$OM_AZURE_CLIENT_ID"
	echo "export OM_AZURE_CLIENT_ID=$OM_AZURE_CLIENT_ID"
	echo "export OM_AZURE_CLIENT_SECRET=$OM_AZURE_CLIENT_SECRET"
	} | tee $OM_ENVIRONMENT_VARS
}

function omDeploy()
{
	sleep 1; echo ""; echo "Creating a self signed certificate for use in the deployment"
	createCert ${OM_DOMAIN_NAME}

	echo "Downloading Terraform templates from Pivnet to pave $OM_IAAS"
	PIVNET_FILE_GLOB="terraforming-${OM_IAAS}*zip"
	PIVNET_PRODUCT_SLUG="elastic-runtime"
	PIVNET_PRODUCT_VERSION="2.6.3"
	WORKSPACE_DIRECTORY="${OM_STATE_DIRECTORY}/workspace"

	mkdir -p ${WORKSPACE_DIRECTORY} 
	cd ${WORKSPACE_DIRECTORY}

	om download-product --pivnet-api-token ${PIVNET_API_TOKEN} --pivnet-file-glob "${PIVNET_FILE_GLOB}" --pivnet-product-slug ${PIVNET_PRODUCT_SLUG} --product-version ${PIVNET_PRODUCT_VERSION} --output-directory .

	unzip ${PIVNET_FILE_GLOB}
	cd pivotal-cf-terraforming-*/terraforming-pks

	# downloading ops manager yml to parse location of oms-mgr image in azure
	# om download-product --pivnet-api-token iigMJxjc3wkqxRiknHR1 --pivnet-file-glob "ops-manager-azure*yml" --pivnet-product-slug ops-manager --product-version 2.6.5 --output-directory .

if [ $OM_IAAS == "gcp" ]; then

	cat <<EOT > terraform.tfvars
env_name         = "$OM_ENV_NAME"
opsman_image_url = "ops-manager-us/pcf-gcp-2.6.6-build.179.tar.gz"
region           = "us-east4"
zones            = ["us-east4-a", "us-east4-b", "us-east4-c"]
project          = "${GCP_PROJECT_ID}"
dns_suffix       = "${OM_DOMAIN_NAME}"

ssl_cert = <<SSL_CERT
`cat $OM_CERT`
SSL_CERT

ssl_private_key = <<SSL_KEY
`cat $OM_CERT_PRIV_KEY`
SSL_KEY

service_account_key = <<SERVICE_ACCOUNT_KEY
`cat $OM_GCP_SERVICE_ACCOUNT_KEY`
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

	terraform init
	terraform plan -out=plan
	terraform apply plan
}

function azureConfigure()
{
	OM_ADMIN_USER="admin"
	OM_ADMIN_PASSWORD="password"
	OM_ADMIN_DECRYPT_PASSPHRASE="keepitsimple"
	
	om -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k configure-authentication \
		--username admin \
		--password applep13 \
		--decryption-passphrase applep13

	# azure config page
	terraform output subscription_id
	terraform output tenant_id
	terraform output client_id
	terraform output client_secret
	terraform output pcf_resource_group_name
	terraform output ops_manager_storage_account
	terraform output bosh_deployed_vms_security_group_name #default security group
	terraform output ops_manager_ssh_public_key
	terraform output ops_manager_ssh_private_key
	#availability Zones

	# director config page
	time.windows.com # public ntp server
	# enable VM resurrector plugin
	# enable post deploy scripts
	# recreate all VM's

	# create networks page
	# network name = infrastructure
	TF_OUT_NETWORK="`terraform output network_name`"
	TF_OUT_INFRA_SUBNET="`terraform output infrastructure_subnet_name`"
	echo "${TF_OUT_NETWORK}/${TF_OUT_INFRA_SUBNET}"
	terraform output infrastructure_subnet_cidrs
	# dns = 168.63.129.16
	terraform output infrastructure_subnet_gateway

	# network name = pks
	terraform output network_name
	TF_OUT_PKS_SUBNET="`terraform output pks_subnet_name`"
	echo "${TF_OUT_NETWORK}/${TF_OUT_PKS_SUBNET}"
	terraform output pks_subnet_name
	terraform output pks_subnet_cidrs
	# dns = 168.63.129.16
	terraform output pks_subnet_gateway

	# network name = services 
	terraform output network_name
	TF_OUT_SERVICES_SUBNET="`terraform output services_subnet_name`"
	echo "${TF_OUT_NETWORK}/${TF_OUT_SERVICES_SUBNET}"
	terraform output services_subnet_name
	terraform output services_subnet_cidrs
	# dns = 168.63.129.16
	terraform output services_subnet_gateway

	## Assign AZs and Networks
	# Singleton AZ = zone-1
	# Network = infrastructure

	## Security
	# include opsmanager root ca in trusted certs
	# generate passwords

	om -t https://pcf.omwraprc1.azure.harnessingunicorns.io -k -u admin -p applep13 apply-changes

}

function gcpConfigure()
{
	OM_ADMIN_USER="admin"
	OM_ADMIN_PASSWORD="password"
	OM_ADMIN_DECRYPT_PASSPHRASE="keepitsimple"
	
	om -t https://pcf.${OM_ENV_NAME}.${OM_DOMAIN_NAME} -k configure-authentication \
		--username admin \
		--password applep13 \
		--decryption-passphrase applep13

	## gcp config page
	terraform output project_id

	## director config
	# time.google.com
	# enable VM resurrector plugin
        # enable post deploy scripts
        # recreate all VM's

        ## create availability zones
	terraform output azs
	terraform output azs[0]

        ## create networks page
        # network name = infrastructure
        TF_OUT_NETWORK="`terraform output network_name`"
        TF_OUT_INFRA_SUBNET="`terraform output infrastructure_subnet_name`"
	TF_OUT_REGION="`terraform output region`"
        echo "${TF_OUT_NETWORK}/${TF_OUT_INFRA_SUBNET}/${TF_OUT_REGION}"
        terraform output infrastructure_subnet_cidrs
        # dns = 168.63.129.16
        terraform output infrastructure_subnet_gateway

        # network name = pks
        terraform output network_name
        TF_OUT_PKS_SUBNET="`terraform output pks_subnet_name`"
        echo "${TF_OUT_NETWORK}/${TF_OUT_PKS_SUBNET}/${TF_OUT_REGION}"
        terraform output pks_subnet_name
        terraform output pks_subnet_cidrs
        # dns = 168.63.129.16
        terraform output pks_subnet_gateway

        # network name = services
        terraform output network_name
        TF_OUT_SERVICES_SUBNET="`terraform output services_subnet_name`"
        echo "${TF_OUT_NETWORK}/${TF_OUT_SERVICES_SUBNET}/${TF_OUT_REGION}"
        terraform output services_subnet_name
        terraform output services_subnet_cidrs
        # dns = 168.63.129.16
        terraform output services_subnet_gateway

        ## Assign AZs and Networks
        # Singleton AZ = zone-1
        # Network = infrastructure

        ## Security
        # generate passwords

}

if [ $OM_IAAS == "gcp" ]; then
	gcpInitialize
	omDeploy
	gcpConfigure
elif [ $OM_IAAS == "aws" ]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [ $OM_IAAS == "vsphere" ]; then
	echo "$OM_IAAS not implemented yet"
	exit 1
elif [ $OM_IAAS == "azure" ]; then
	azureInitialize
	omDeploy
	azureConfigure
else
	echo "${OM_IAAS} is not a valid selection.  Exiting!"
	exit 1
fi

exit
echo "";echo ""
echo "Now your IAAS should be set and ready to use bbl to create a bosh environment."
echo ""; echo "What you should do now:"
echo "# The following will enable the bbl command by sourcing the required env vars"
echo "source $OM_ENVIRONMENT_VARS"
echo "bbl -h                        # familiarize yourself with bbl generally"
echo "bbl plan -h                    # familiarize yourself with the bbl plan command line options"
echo "bbl up -h                    # familiarize yourself with the bbl up command line options"
echo "bbl plan --lb-type concourse --debug        # this will create lots of structures in \$OM_STATE_DIRECTORY"
echo "";echo "# after executing bbl plan, now you can go into \$OM_STATE_DIRECTORY and make edits and customizations"
echo "";echo "bbl up --lb-type concourse --debug        # this will execute the plan with customizations on your IAAS"

echo "";echo ""
echo "Checkout the README.md for additional next steps.  Thanks for using bblwrap!"
