// ============================================================
// SharePoint Multimodal RAG Kit — IaC (from scratch, single region)
//
// Creates EVERYTHING needed for the ACL-preserving, multimodal Azure AI
// Search pipeline in ONE region (Sweden Central, which supports Content
// Understanding, the required models, and Vision multimodal embeddings):
//   - Azure AI Search service (system-assigned MI, RBAC data-plane enabled)
//   - Foundry (AIServices) account for Content Understanding + text embeddings
//   - Model deployments: text-embedding-3-large + gpt-4.1-mini
//   - Azure AI Vision (AIServices) account for multimodal image embeddings
//   - Role assignments: Search MI -> Foundry and Search MI -> Vision
//     (Cognitive Services User); optionally the deploying user -> Search
//     Index Data Reader (so token-based queries / query.py work).
//
// MANUAL PREREQUISITES (cannot be provisioned here):
//   - Entra app registration with Graph Files.Read.All + Sites.FullControl.All
//     (admin-consented) + a client secret — used by the SharePoint indexer.
//   - SharePoint indexer preview registration (aka.ms/azure-cognitive-search/indexer-preview).
//   - A SharePoint site/library with documents to index.
//
// TEARDOWN: everything is deployed into a single dedicated resource group
// ($env:AZ_RG, created by scripts/01-provision-resources.ps1). To remove the
// entire project:  az group delete --name <AZ_RG> --yes
// ============================================================

targetScope = 'resourceGroup'

// ---------- Parameters ----------
// All resources are co-located in one region that supports CU + Vision + models.
param location string = 'swedencentral'

// Resource names
param searchName string
param searchSku string = 'standard'
param foundryName string
param visionName string

// Model deployments (on the Foundry account)
param createDeployments bool = true
param embedDeployment string = 'text-embedding-3-large'
param embedModel string = 'text-embedding-3-large'
param embedSku string = 'Standard'
param embedCapacity int = 30
param cuModelDeployment string = 'gpt-4.1-mini'
param cuModelName string = 'gpt-4.1-mini'
param gptSku string = 'Standard'
param gptCapacity int = 100

// Optional: grant the deploying user query access (Search Index Data Reader)
param queryPrincipalId string = ''

// ---------- Role Definition IDs ----------
var cogSvcUserRole        = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
var searchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader

// ============================================================
// Azure AI Search service (system MI + RBAC data-plane auth)
// ============================================================
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  sku: {
    name: searchSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    // Allow both API keys and Microsoft Entra (RBAC) data-plane auth.
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// ============================================================
// Foundry (AIServices) — Content Understanding + text embeddings + GPT
// ============================================================
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Custom subdomain is required for AAD/MI token auth (used by the search MI).
    customSubDomainName: foundryName
  }
}

resource embedDeploy 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (createDeployments) {
  parent: foundry
  name: embedDeployment
  sku: {
    name: embedSku
    capacity: embedCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embedModel
    }
  }
}

resource gptDeploy 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (createDeployments) {
  parent: foundry
  name: cuModelDeployment
  sku: {
    name: gptSku
    capacity: gptCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: cuModelName
    }
  }
  dependsOn: [
    embedDeploy
  ]
}

// ============================================================
// Azure AI Vision (AIServices) — multimodal image embeddings
//   Used by the AI Search query-time vectorizer (aiServicesVision) and the
//   VectorizeSkill. Must be in a region that supports multimodal embeddings.
// ============================================================
resource vision 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: visionName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: visionName
  }
}

// ============================================================
// Role Assignments
// ============================================================

// --- Search MI -> Foundry (Content Understanding + text embeddings) ---
resource raSearchOnFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, foundry.id, cogSvcUserRole)
  scope: foundry
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cogSvcUserRole)
  }
}

// --- Search MI -> Vision (query-time image vectorizer + VectorizeSkill) ---
resource raSearchOnVision 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, vision.id, cogSvcUserRole)
  scope: vision
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cogSvcUserRole)
  }
}

// --- (Optional) deploying user -> Search Index Data Reader (token queries) ---
resource raQueryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(queryPrincipalId)) {
  name: guid(search.id, queryPrincipalId, searchIndexDataReader)
  scope: search
  properties: {
    principalId: queryPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReader)
  }
}

// ============================================================
// Outputs
// ============================================================
output searchEndpoint string    = 'https://${search.name}.search.windows.net'
output foundryEndpoint string   = foundry.properties.endpoint
output foundryName string       = foundry.name
output visionEndpoint string    = vision.properties.endpoint
output searchPrincipalId string = search.identity.principalId
