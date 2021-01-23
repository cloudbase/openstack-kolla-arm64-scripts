# We are using the Azure Container Registry, but any other container registry would work
az login
# If you have more than one Azure subscription, choose one:
az account list --output table
az account set --subscription "Your subscription"

RG=kolla
ACR_NAME=your_registry_name_here

az group create --name $RG --location eastus
az acr create --resource-group $RG --name $ACR_NAME --sku Basic

ACR_REGISTRY_ID=$(az acr show --name $ACR_NAME --query id --output tsv)

SERVICE_PRINCIPAL_NAME=acr-kolla-sp-push
SP_PASSWD=$(az ad sp create-for-rbac --name http://$SERVICE_PRINCIPAL_NAME --scopes $ACR_REGISTRY_ID --role acrpush --query password --output tsv)
SP_APP_ID=$(az ad sp show --id http://$SERVICE_PRINCIPAL_NAME --query appId --output tsv)
echo "Push / pull service SP_APP_ID=$SP_APP_ID"
echo "Push / pull service SP_PASSWD=$SP_PASSWD"

SERVICE_PRINCIPAL_NAME=acr-kolla-sp-pull
SP_PASSWD=$(az ad sp create-for-rbac --name http://$SERVICE_PRINCIPAL_NAME --scopes $ACR_REGISTRY_ID --role acrpull --query password --output tsv)
SP_APP_ID=$(az ad sp show --id http://$SERVICE_PRINCIPAL_NAME --query appId --output tsv)
echo "Pull only service SP_APP_ID_PULL_ONLY=$SP_APP_ID"
echo "Pull only service SP_PASSWD_PULL_ONLY=$SP_PASSWD"

REGISTRY=$ACR_NAME.azurecr.io
# Back on the ansible node, you can login to the container registry $ACR_NAME.azurecr.io
# using SP_APP_ID and SP_PASSWD

sudo apt update
sudo apt install -y docker-ce python3-venv git

sudo usermod -aG docker $USER
newgrp docker

docker login $REGISTRY --username $SP_APP_ID --password $SP_PASSWD

mkdir kolla-build
cd kolla-build
python3 -m venv venv
source venv/bin/activate
#python3 -m pip install tox
pip install wheel
# Install Kolla, Ussuri version
pip install "kolla>=10,<11"

# The pmdk-tools package is not available on ARM64
tee template-overrides.j2 << EOT
{% extends parent_template %}

# nova-compute
{% set nova_compute_packages_remove = ['pmdk-tools'] %}
EOT

# This will build the container images and push them to the registry
kolla-build -b ubuntu --registry $REGISTRY --template-override template-overrides.j2 --push

# Note: the last command will build all the images, if you want just a subset,
# please check the profiles section in https://docs.openstack.org/kolla/latest/admin/image-building.html

# Another way to build a limited set of images:
# kolla-build -b ubuntu --registry $REGISTRY --template-override template-overrides.j2 nova
