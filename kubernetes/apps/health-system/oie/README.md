# Open Integration Engine

This app deploys Open Integration Engine as the first open-source integration-engine layer for the ORBIS-like HL7 lab.

## Scope

- internal-only admin access
- PostgreSQL-backed OIE runtime
- persistent appdata volume
- no channels bootstrapped yet
- intended first use: `FHIR/JSON over HTTP -> transform -> HL7 v2 -> Medplum`

## Endpoints

- Admin UI: `https://oie.rbl.lol`

## Notes

- The ingress is internal only.
- This deploy exposes the OIE admin/API surface, not a finished channel pack.
- The next step after deploy is creating a first HTTP-to-HL7 channel and pointing it at Medplum.
