# Setup

This guide deploys the workflow to your own Azure subscription. Every environment value lives in your local `.env` file. Nothing in the repo points to a real environment.

## Prerequisites

- Azure CLI 2.60 or later, signed in with `az login`
- `jq` and `zip`
- A Microsoft Foundry resource with a Microsoft-Decision-1 deployment. See [Deploy and use Microsoft-Decision-1](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision).
- Permission to create resources and role assignments. For example Owner, or Contributor plus User Access Administrator.

## Repo layout

```
zucca-fan-mail-radar/workflow.json   the workflow definition
host.json                            Logic Apps runtime config
deploy.sh                            sets app settings and zip deploys to your Logic App
test.sh                              sends the test messages and checks the results
test-data/messages.json              fictional test messages with expected next actions
scan.sh                              pre-publish scan for secrets and your real values
.env.example                         every setting you need, as placeholders
```

## 1. Fill in .env

```bash
cp .env.example .env
```

Find your Foundry resource, endpoint, and deployment name:

```bash
az cognitiveservices account list --query "[].{name:name, rg:resourceGroup, location:location, endpoint:properties.endpoint}" -o table
az cognitiveservices account deployment list -g <your-foundry-resource-group> -n <your-foundry-resource-name> -o table
```

Use the endpoint without a trailing `/`. For `DECISION_DEPLOYMENT_NAME`, use the deployment name, not the model name.

## 2. Pick a WS1 plan

The Logic App runs on a Workflow Standard (WS1) App Service plan. Find an existing one:

```bash
az appservice plan list --query "[?sku.name=='WS1'].{name:name, rg:resourceGroup, location:location, apps:numberOfSites}" -o table
```

Pick one in the same region as your Foundry resource. Put its name and resource group in `.env`. Create the Logic App and storage account in that same resource group and region.

If you don't have a plan, create one. WS1 is billed while it exists.

```bash
az appservice plan create -g <your-resource-group> -n <your-plan-name> -l <your-region> --sku WS1
```

## 3. Create the Logic App

```bash
set -a; source .env; set +a

az storage account create -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false \
  --tags project=zucca-fan-mail-radar

az logicapp create -n "$LOGIC_APP_NAME" -g "$RESOURCE_GROUP" \
  --plan "$(az appservice plan show -g "$PLAN_RESOURCE_GROUP" -n "$PLAN_NAME" --query id -o tsv)" \
  --storage-account "$STORAGE_ACCOUNT" --functions-version 4 --https-only true \
  --disable-app-insights --tags project=zucca-fan-mail-radar

az webapp identity assign -n "$LOGIC_APP_NAME" -g "$RESOURCE_GROUP" --query principalId -o tsv
```

Put the printed principal ID in `.env` as `LOGIC_APP_PRINCIPAL_ID`.

Keep the `project=zucca-fan-mail-radar` tag. `deploy.sh` refuses to deploy to a Logic App without it. That way a typo in `.env` can't overwrite another app on a shared plan.

## 4. Give the Logic App access to Foundry

```bash
set -a; source .env; set +a

az role assignment create \
  --assignee-object-id "$LOGIC_APP_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$(az cognitiveservices account show -n "$FOUNDRY_RESOURCE_NAME" -g "$FOUNDRY_RESOURCE_GROUP" --query id -o tsv)"
```

The role is scoped to the Foundry resource only. It can take a few minutes to take effect.

## 5. Deploy and test

```bash
./deploy.sh
./test.sh          # results table with PASS/FAIL, plus 400 checks for invalid input
./test.sh --raw    # also prints each JSON response
```

`deploy.sh` sets two app settings, `FOUNDRY_ENDPOINT` and `DECISION_DEPLOYMENT_NAME`. The workflow reads them with `@appsetting(...)`. Then it zip deploys the workflow.

`test.sh` fetches the trigger URL at run time and keeps it in memory. See [PRODUCTION.md](PRODUCTION.md) for why.

A sample response:

```json
{
  "product": "salmon_crunch",
  "happiness": "Superfan (2.00)",
  "shareable_story": "Yes (100%)",
  "share_permission": "Yes (100%)",
  "flavor_request": "none",
  "next_action": "Send to Marketing as testimonial"
}
```

## Clean up

If the resource group is shared with other resources, don't delete the resource group. Delete only what this project created:

```bash
set -a; source .env; set +a

# 1. Remove the role assignment on the Foundry resource
az role assignment delete --assignee "$LOGIC_APP_PRINCIPAL_ID" --role "Cognitive Services User" \
  --scope "$(az cognitiveservices account show -n "$FOUNDRY_RESOURCE_NAME" -g "$FOUNDRY_RESOURCE_GROUP" --query id -o tsv)"

# 2. Delete the Logic App. This also removes its managed identity.
az logicapp delete -n "$LOGIC_APP_NAME" -g "$RESOURCE_GROUP"

# 3. Delete its storage account
az storage account delete -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --yes
```

Don't delete the WS1 plan if other apps use it. Check first:

```bash
az appservice plan show -g "$PLAN_RESOURCE_GROUP" -n "$PLAN_NAME" --query numberOfSites
```
