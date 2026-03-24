# Support Access Guardrails

This app contains the customer-side RBAC switch and the admission policy that
protects the reserved support RBAC objects from accidental mutation.

Managed here:

- `Namespace/support-access-system`
- `ServiceAccount/support-switch-sa`
- `ClusterRole/support-switch-rbac-manager`
- `ClusterRoleBinding/support-switch-rbac-manager`
- `ValidatingAdmissionPolicy/protect-support-rbac`
- `ValidatingAdmissionPolicyBinding/protect-support-rbac`

The reserved vendor access role and binding are controlled locally through the
support switch path. The hub only delivers the OCM access plumbing and support
identity.
