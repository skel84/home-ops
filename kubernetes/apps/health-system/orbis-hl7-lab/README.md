# ORBIS-like HL7 Lab

This path started as documentation-only planning for an ORBIS-like HL7 lab.

That is no longer strictly true:

- the first live integration-engine slice now exists under [oie](/Users/francesco/repos/homelab/home-ops/kubernetes/apps/health-system/oie)
- the matching database app now exists under [oie-postgresql](/Users/francesco/repos/homelab/home-ops/kubernetes/apps/health-system/oie-postgresql)
- the matching Argo CD apps now exist under [health-system](/Users/francesco/repos/homelab/home-ops/kubernetes/argo/apps/health-system)

This document remains useful as the broader lab rationale, but it should be read alongside the OIE deployment manifests rather than as a statement that nothing is deployed.

## Goal

Build an integration lab that behaves like an ORBIS-style HL7 environment for interface testing. The lab should cover broad ADT traffic, ORM orders, ORU results, and MDM document flows without trying to model a full HIS.

## Current Decision

Original planning pipeline:

`HL7 simulator -> MLLP -> gateway-hl7-listener -> NATS JetStream (raw HL7) -> custom Java converter-publisher -> NATS JetStream (FHIR) -> downstream apps`

Current deployed direction is different for the first open-source lab slice:

`Synthea or synthetic HTTP/FHIR input -> OIE -> HL7 v2 -> Medplum`

The LinuxForHealth plus NATS path is still a valid alternative lab design, but it is not the only tracked direction anymore.

## Phase Boundaries

### Phase 0: Planning and backlog

Deliverables:

- architecture brief
- local `taskwarrior` execution queue
- source validation against LinuxForHealth and NATS docs

Explicitly out of scope:

- `home-ops` manifests
- Argo CD applications
- GitOps wiring
- cluster deployment from this repo

### Phase 1: Local validation lab outside `home-ops`

Run the lab outside `home-ops` GitOps, using local tooling or a disposable environment, until the message flow and replay behavior are proven.

Deliverables:

- NATS JetStream running with persistent storage
- `gateway-hl7-listener` receiving HL7 over MLLP and publishing raw HL7
- Java converter-publisher consuming raw HL7 and publishing converted FHIR
- test sender and ORBIS-like message pack
- replay test proving raw HL7 can be reprocessed after converter outage or redeploy

Exit criteria:

- sender can submit `ADT`, `ORM^O01`, `ORU^R01`, and `MDM^T02`
- raw HL7 is durable and replayable
- downstream consumers read from the FHIR stream through durable consumers
- converter failure does not destroy ingress durability

### Phase 2: Manual deployment preparation

Only after phase 1 is green:

- prepare Kubernetes manifests for manual `kubectl apply`
- keep deployment non-GitOps initially
- decide which resources belong in `home-ops` and which should stay external

This repo should not get phase-2 manifests until phase-1 validation is complete and the deployment boundary is agreed.

## Work Packages

### 1. Scope and acceptance

Define the minimum message pack and confirm phase gates.

Scope:

- ADT: `A04`, `A08`, `A01`, `A03`, `A40`
- Orders: `ORM^O01`
- Results: `ORU^R01`
- Documents: `MDM^T02`

Acceptance:

- every message type has at least one representative test payload
- every payload has an expected downstream FHIR outcome or documented converter limitation

### 2. Messaging foundation

Design the durable messaging backbone before building deployment artifacts.

Baseline:

- raw subject family: `hl7.raw.*`
- converted subject family: `fhir.bundle.*`
- separate raw and converted streams
- one durable consumer per downstream app
- start with 3 JetStream nodes for HA when moving beyond local single-node validation

Acceptance:

- stream names, subjects, retention, and replay expectations are documented
- consumer naming and ownership are documented per downstream app

### 3. Listener validation

Validate that `gateway-hl7-listener` is the ingress durability boundary.

Acceptance:

- MLLP ingest succeeds
- JetStream publish acknowledgement succeeds
- listener behavior on publish or acknowledgement failure is observed and documented

### 4. Converter-publisher service

Implement a small Java worker around LinuxForHealth's converter library.

Responsibilities:

- consume raw HL7 from JetStream
- convert via `HL7ToFHIRConverter().convert(hl7Message)`
- publish FHIR JSON to the converted stream
- attach app metadata outside the raw HL7 payload

Acceptance:

- supported event set is limited to the agreed phase-1 message pack
- converter logs avoid PHI leakage
- failed conversions are observable and replayable from raw HL7

### 5. Test data and replay

Build a deterministic message pack and outage test.

Acceptance:

- replaying raw HL7 reproduces the same downstream behavior
- duplicate handling and idempotency expectations are documented
- merge behavior for `A40` is explicitly tested

### 6. Deployment readiness

Prepare the manual deployment path only after the local lab is stable.

Acceptance:

- namespace, storage, and secret inputs are identified
- manual apply order is written down
- runtime checks are listed for NATS, listener, converter, and downstream consumers

## Risks and controls

- Ingress/conversion coupling risk: keep listener and converter separate.
- PHI leakage risk: keep logs minimal and avoid raw-payload logging in non-debug paths.
- Replay drift risk: retain raw HL7 unchanged and treat converted FHIR as derived output.
- Premature GitOps risk: delay `home-ops` manifests until the local lab is proven.

## Relevant Docs

LinuxForHealth:

- Listener README: <https://github.com/LinuxForHealth/gateway-hl7-listener>
- Converter README: <https://github.com/LinuxForHealth/hl7v2-fhir-converter>
- FHIR Server README: <https://github.com/LinuxForHealth/FHIR>

NATS:

- JetStream clustering: <https://docs.nats.io/running-a-nats-service/configuration/clustering/jetstream_clustering>
- JetStream consumers: <https://docs.nats.io/nats-concepts/jetstream/consumers>

## Source Notes

These points are the working basis for the plan:

- `gateway-hl7-listener` is a Python service that listens for MLLP HL7, publishes to JetStream, and halts intake when publish or acknowledgement fails.
- `hl7v2-fhir-converter` is a Java library, not a standalone service, and supports the phase-1 event set needed here including `ADT_A01`, `ADT_A03`, `ADT_A04`, `ADT_A08`, `ADT_A40`, `ORM_O01`, `ORU_R01`, and `MDM_T02`.
- JetStream clustering guidance recommends 3 or 5 JetStream-enabled servers for HA, and durable consumers persist state and can recover from client or server failure.
- The LinuxForHealth FHIR Server is deferred because phase 1 only needs event delivery, not a queryable canonical FHIR store.
