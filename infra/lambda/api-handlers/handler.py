"""
API Handlers Lambda — Phase 2A

Triggered by: API Gateway HTTP API
Reads from:   All DynamoDB tables (scoped by role)

Routes:
  GET  /api/v1/device/{serial}              → device health + status
  GET  /api/v1/activity/{serial}?range=...  → activity data
  GET  /api/v1/alerts/{serial}              → alert history
  GET  /api/v1/me/walkers                   → caregiver's linked walkers
  POST /api/v1/device/activate              → link serial to user

Role scoping:
  - JWT claims include cognito:groups (walker | caregiver)
  - Walker: can only query own device (matched via linked_devices attribute)
  - Caregiver: can query any linked walker (checked via relationships table)
  - All unauthorized access returns 403
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 2A
    print(json.dumps(event))

    path = event.get("rawPath", "")
    method = event.get("requestContext", {}).get("http", {}).get("method", "")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "API handler placeholder",
            "path": path,
            "method": method,
        }),
    }
