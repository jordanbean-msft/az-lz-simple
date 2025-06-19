set -e

echo "Building DNS Resolver Docker image..."

while IFS='=' read -r key value; do
    value=$(echo "$value" | sed 's/^"//' | sed 's/"$//')
    export "$key=$value"
done <<EOF
$(azd env get-values)
EOF

# generate a unique, alphanumeric, <50 char ACR name starting with 'cr'
acr_env=$(echo "$AZURE_ENV_NAME" | tr -cd '[:alnum:]' | cut -c1-10)
acr_loc=$(echo "$AZURE_LOCATION" | tr -cd '[:alnum:]' | cut -c1-10)
acr_sub=$(echo "$AZURE_SUBSCRIPTION_ID" | tr -cd '[:alnum:]' | sha1sum | cut -c1-8)
ACR_NAME="cr${acr_env}${acr_loc}${acr_sub}"
ACR_NAME=$(echo "$ACR_NAME" | cut -c1-49)

echo "Deploying Azure Container Registry with name: $ACR_NAME..."

# deploy Azure Container Registry
az acr create \
  --name $ACR_NAME \
  --resource-group $AZURE_RESOURCE_GROUP_NAME \
  --sku Basic \
  --location $AZURE_LOCATION \
  --admin-enabled false

echo "Azure Container Registry $ACR_NAME created successfully."

# get current date for tagging
current_date=$(date +%Y%m%d%H%M%S)

image_name=$ACR_NAME.azurecr.io/az-lz-simple/dns-resolver:$current_date

echo "Building DNS Resolver Docker image $image_name..."

docker build -t $image_name --platform=linux/amd64 src/dns

echo "DNS Resolver Docker image built successfully."

# login to ACR
az acr login --name $ACR_NAME

echo "Pushing DNS Resolver Docker image $image_name to Azure Container Registry..."

# push the image to ACR
docker push $image_name

echo "DNS Resolver Docker image pushed successfully."

# set AZD environment variable for the ACR name
azd env set AZURE_CONTAINER_REGISTRY_NAME $ACR_NAME

# set AZD environment variable for the ACR image name
azd env set AZURE_DNS_RESOLVER_IMAGE_NAME $image_name
