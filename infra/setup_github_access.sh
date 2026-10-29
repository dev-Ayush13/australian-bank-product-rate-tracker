#!/usr/bin/env bash
# One-off setup (DR-005): lets the GitHub Actions workflow on main add and remove its own firewall rule on the SQL server.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # stop Git Bash on Windows rewriting /subscriptions/... into a file path

RG=rg-bank-tracker
SQL_SERVER=ayush-bank-tracker-sql
IDENTITY=id-bank-tracker-github
ROLE="SQL firewall rule operator (bank tracker)"
REPO=dev-Ayush13/australian-bank-product-rate-tracker

SUB_ID=$(az account show --query id -o tsv)
SERVER_ID=$(az sql server show -g "$RG" -n "$SQL_SERVER" --query id -o tsv)

#1. Identity the workflow logs in as (no password or key)
az identity create -g "$RG" -n "$IDENTITY" -l australiaeast -o none
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)

#2. Role that can only read, add and delete firewall rules, assigned on this server only
[ -n "$(az role definition list --name "$ROLE" --custom-role-only true --query "[].roleName" -o tsv)" ] ||
az role definition create -o none --role-definition "{
  \"Name\": \"$ROLE\",
  \"Description\": \"Read, create and delete firewall rules on SQL servers. Nothing else.\",
  \"Actions\": [\"Microsoft.Sql/servers/firewallRules/read\", \"Microsoft.Sql/servers/firewallRules/write\", \"Microsoft.Sql/servers/firewallRules/delete\"],
  \"AssignableScopes\": [\"/subscriptions/$SUB_ID/resourceGroups/$RG\"]
}"
for attempt in 1 2 3 4 5 6; do  # a new role can take a minute to become usable
  az role assignment create -o none --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role "$ROLE" --scope "$SERVER_ID" && break
  [ "$attempt" = 6 ] && exit 1
  sleep 20
done

#3. Trust tokens from GitHub Actions only for this repo's main branch
az identity federated-credential create -o none -g "$RG" --identity-name "$IDENTITY" -n github-main \
  --issuer https://token.actions.githubusercontent.com \
  --subject "repo:$REPO:ref:refs/heads/main" \
  --audiences api://AzureADTokenExchange

#4. Check
az role assignment list --assignee "$PRINCIPAL_ID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
az identity federated-credential list -g "$RG" --identity-name "$IDENTITY" --query "[].{name:name, subject:subject}" -o table
