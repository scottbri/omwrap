#!/bin/bash

# --------------------------------------------------
# Create a new GCP service account and set relevant GCP environment variables
# Requires: the command gcloud in the path
# --------------------------------------------------

if [ $# -lt 2 ] ; then
        echo "Usage: $0 OM_STATE_DIRECTORY OM_ENVIRONMENT_VARS"
        echo ""
        exit 1
fi

OM_STATE_DIRECTORY="${1}"
OM_ENVIRONMENT_VARS="${2}"
OM_IAAS="gcp"

if [ -r ${OM_ENVIRONMENT_VARS} ]; then source ${OM_ENVIRONMENT_VARS}; fi

gcloud -v >/dev/null 2>&1 || { echo "gcloud command required in path" && exit 1 }

# ---- set GCP_PROJECT ----
RESETVAR=true # assume we're going to reset the var
if [ ! -z ${GCP_PROJECT+x} ]; then # if it is already set to something
	askYes "Your GCP Project ID is set to $GCP_PROJECT_ID.  Keep it?"; RETVAL=$?
	if [ $RETVAL -eq 0 ]; then RESETVAR=false; fi # don't reset it
fi
if [ $RESETVAR = true ]; then
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
fi

# ---- set GCP_SERVICE_ACCOUNT ----
RESETVAR=true
if [ ! -z ${GCP_SERVICE_ACCOUNT_NAME+x} ]; then 
        askYes "Your GCP Service Account Name is set to $GCP_SERVICE_ACCOUNT_NAME.  Keep it?"; RETVAL=$?
        if [ $RETVAL -eq 0 ]; then RESETVAR=false; fi # don't reset it
fi
if [ $RESETVAR = true ]; then
	echo ""; echo "Creating a new service account in GCP that will own the deployment"
	GCP_SERVICE_ACCOUNT_NAME="`echo $OM_ENV_NAME | awk '{print tolower($0)}'`""serviceaccount"
	echo "$ gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME"
	gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME
	RETVAL=$?
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi

	GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

	sleep 1; echo ""; echo "Now I need to create a service account key. I'll store it here:"
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
	if [[ $RETVAL -eq 1 ]]; then echo "Hmmm.  You may need to execute a \"gcloud init\" if you're having issues with permissions."; exit 1; fi

fi

# ---- set GCP_REGION ----
RESETVAR=true
if [ ! -z ${GCP_REGION+x} ]; then 
        askYes "Your GCP Region is set to $GCP_REGION.  Keep it?"; RETVAL=$?
        if [ $RETVAL -eq 0 ]; then RESETVAR=false; fi # don't reset it
fi
if [ $RESETVAR = true ]; then
	sleep 1; echo ""; echo "Here is a list of regions where BOSH can be deployed"
	echo "$ gcloud compute regions list"
	gcloud compute regions list
	GCP_REGION="$(askUser "Please input the name of one of these regions for the deployment")"

	sleep 1; echo ""; echo "Here is a list of zones for that region"
	echo "$ gcloud compute zones list | grep ${GCP_REGION}"
	gcloud compute zones list | grep ${GCP_REGION} | readarray ZONES
	echo "$ZONES[@]"
	GCP_AZ1="$ZONES[0]"
	GCP_AZ2="$ZONES[1]"
	GCP_AZ3="$ZONES[2]"

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

