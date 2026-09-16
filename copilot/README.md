# Finance Documents agent for Microsoft 365 Copilot

A **declarative agent** package for https://copilot.microsoft.com. Once
uploaded, "Finance Documents" appears under *Agents* in Copilot and answers
invoice / purchase-order questions by calling the Azure ML endpoint that serves
the fine-tuned Qwen model.

```
copilot.microsoft.com  ->  Copilot orchestrator  ->  API plugin (OAuth, as the signed-in user)
                        ->  https://docintel-qwen.eastus.inference.ml.azure.com/score
                        ->  Qwen2.5-3B + finance adapter  ->  answer from the weights
```

Note what this is NOT: it does not route through the Foundry agent. Copilot's
own orchestrator plays the gpt-4.1-mini role and calls the endpoint directly.
Same model, same answers, one fewer hop.

## Files

| File | What it is |
|---|---|
| `manifest.json` | Teams app manifest (v1.19) declaring the agent |
| `declarativeAgent.json` | the agent: name, instructions, conversation starters, the action it may call |
| `ai-plugin.json` | the API plugin: which OpenAPI operation, and how to authenticate |
| `finance-qwen.openapi.yaml` | the endpoint's OpenAPI spec with the live URL |
| `color.png`, `outline.png` | icons |

## Blocked on two admin actions

The package is complete except for two values that only a **tenant admin**
can produce. A non-admin user cannot: the tenant does not allow users to
register applications (`az ad app create` -> Insufficient privileges), and the
account holds no directory role.

### 1. An Entra app registration (for OAuth)

Copilot must obtain a token for the signed-in user to call the AAD-protected
endpoint. Ask an admin to run:

```bash
APPID=$(az ad app create --display-name docintel-copilot-finance \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect \
  --query appId -o tsv)
az ad app credential reset --id $APPID --display-name copilot-plugin --years 1 --query password -o tsv
# delegated permission: Azure Machine Learning Services / user_impersonation
az ad app permission add --id $APPID --api 18a66f5f-dbdf-4c17-9dd7-1634712a9cbe \
  --api-permissions "$(az ad sp show --id 18a66f5f-dbdf-4c17-9dd7-1634712a9cbe \
     --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv)=Scope"
az ad app permission admin-consent --id $APPID
```

Keep the app id and secret; they go into the Developer Portal, never into
this folder.

### 2. An OAuth client registration in the Teams Developer Portal

https://dev.teams.microsoft.com -> **Tools -> OAuth client registration -> New**

| Field | Value |
|---|---|
| Registration name | `docintel-finance-endpoint` |
| Base URL | `https://docintel-qwen.eastus.inference.ml.azure.com` |
| Client ID / secret | from step 1 |
| Authorization endpoint | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize` |
| Token endpoint | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token` |
| Scope | `https://ml.azure.com/.default offline_access` |
| PKCE | enabled |

It returns a **registration ID**. Put it in `ai-plugin.json` at
`runtimes[0].auth.reference_id` (replacing `REPLACE_WITH_OAUTH_REGISTRATION_ID`).

Also replace `REPLACE_WITH_A_NEW_GUID` in `manifest.json` with any new GUID.

## Then: package and upload

```bash
cd copilot
zip -r ../finance-documents-agent.zip manifest.json declarativeAgent.json ai-plugin.json finance-qwen.openapi.yaml color.png outline.png
```

In https://copilot.microsoft.com -> **Agents -> Create / Upload an agent -> upload the zip**.
(If the option is missing, the tenant also blocks custom app upload - the admin
enables it under *Teams admin center -> Teams apps -> Setup policies -> Upload
custom apps*, or publishes the zip org-wide from *M365 admin center ->
Integrated apps -> Upload custom apps*.)

First question triggers an OAuth consent prompt for the endpoint; after that,
ask *"How much do we owe Xenon Energy?"* and expect
`The Xenon Energy invoice INV-35089 totals $47,186.04.`

## Who can invoke the endpoint

The plugin calls the endpoint **as the signed-in user**, so that user needs
`AzureML Data Scientist` (or any role granting `onlineEndpoints/score/action`)
on the endpoint or workspace. A subscription Owner has it.
Other users need a role assignment - the endpoint has no keys.

## Cost

Nothing here bills. The endpoint behind it does (~USD 0.53/hour on the T4)
while it exists.
