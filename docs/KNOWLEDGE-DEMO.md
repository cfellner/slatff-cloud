# Knowledge demo

Same assistant, same question, different answers by Keycloak group. Fictional company Seaside
Widgets Ltd (`demo/knowledge/`). Needs step 3 (model gateway). Status: not run yet.

Two layers:
1. Open WebUI searches a knowledge base only for groups that have access (groups come from Keycloak).
2. The gateway refuses labelled content (`CLASSIFICATION:`) a user's roles do not allow, even if layer 1 is wrong.

## Setup (as carol, about 10 minutes)

1. Sign in as carol, then once as alice in a private window (creates the groups in Open WebUI).
2. Workspace › Knowledge › +
   - **Staff handbook**: files from `demo/knowledge/staff/`; access Private + group `ai-users`.
   - **Board papers**: files from `demo/knowledge/board/`; access Private + group `ai-admins`.
3. Workspace › Models › +
   - **SLATFF Assistant**, base `llama3.2:3b`, knowledge: both bases.
   - Advanced Params › Function Calling: **Legacy** (small models otherwise print raw tool calls).
   - Access: Private + groups `ai-users`, `ai-admins`.

## Test

| Question | alice (ai-users) | carol (ai-admins) |
|---|---|---|
| How many holiday days do I get? | 27 plus bank holidays | 27 plus bank holidays |
| What is Project Lighthouse? | does not know | planned acquisition |
| Is the Worthing warehouse closing? | does not know | yes, June 2027 |

`bash scripts/show-audit.sh`: alice's requests carry `STAFF`, carol's also `BOARD-ONLY`.

## Break layer 1 on purpose

1. As carol, give `ai-users` access to Board papers.
2. As alice, ask about Project Lighthouse. Expected: gateway refuses ("prompt contains BOARD-ONLY content").
3. Check `bash scripts/show-audit.sh`, then remove the access again.

## Limits

- Labels are text markers; unlabelled content passes. Real deployments label at ingestion or use the document system's classification.
- An Open WebUI admin sees all knowledge bases; the gateway still applies Keycloak roles.
- Per request only; earlier answers and chat history are not revoked.
