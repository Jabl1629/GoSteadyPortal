"""
FHIR Projection Lambda — Phase 4A

Triggered by: API Gateway HTTP API (/fhir/R4/*)
Reads from:   Activity, Device, UserProfile tables

FHIR R4 Resource Mappings:
  Patient       → walker user (name, DOB, contact, MRN if linked)
  Observation   → activity metrics per period
                  - Steps: LOINC 55423-8
                  - Distance: custom code
                  - Active minutes: custom code
  Device        → walker cap hardware (serial, firmware, battery)
  RelatedPerson → caregiver ↔ patient link

Routes:
  GET /fhir/R4/Patient/{id}
  GET /fhir/R4/Patient?identifier={mrn}
  GET /fhir/R4/Observation?subject={patientId}&code={loinc}&date={range}
  GET /fhir/R4/Device?patient={patientId}
  GET /fhir/R4/RelatedPerson?patient={patientId}

All responses conform to FHIR R4 JSON (application/fhir+json).
Bundle responses for search queries.
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 4A
    print(json.dumps(event))

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/fhir+json"},
        "body": json.dumps({
            "resourceType": "OperationOutcome",
            "issue": [{
                "severity": "information",
                "code": "informational",
                "diagnostics": "FHIR projection placeholder — Phase 4A"
            }]
        }),
    }
