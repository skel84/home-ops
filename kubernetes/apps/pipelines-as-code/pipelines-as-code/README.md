# Forgejo Pipelines-as-Code onboarding

This application exposes the Pipelines-as-Code controller at
`https://pac.rbl.lol`.
Forgejo is available at `https://forgejo.rbl.lol`; registration is disabled.
The initial `forgejo-admin` user is created from the generated
`forgejo-admin-secret`.
Change that password at first login.

## Add a Forgejo repository

1. In Forgejo, create a personal access token with **Repository: Write** and
   **Issue: Write** scopes. Add **Organization: Read** only when using team-based
   Pipelines-as-Code policies.
2. Create a random webhook secret and store both values in a SOPS-encrypted
   Kubernetes `Secret` named `forgejo-webhook-config` in the namespace where that
   repository's PipelineRuns will execute. The secret must contain the keys
   `provider.token` and `webhook.secret`. Do not place either value in an
   unencrypted manifest or in this repository's documentation.
3. Add the following `Repository` resource to the GitOps application that owns
   that execution namespace. Replace the repository URL and namespace values.

   ```yaml
   apiVersion: pipelinesascode.tekton.dev/v1alpha1
   kind: Repository
   metadata:
     name: example-repository
     namespace: ci-example
   spec:
     url: https://forgejo.rbl.lol/owner/repository
     settings:
       pipelinerun_provenance: default_branch
     git_provider:
       type: forgejo
       url: https://forgejo.rbl.lol
       secret:
         name: forgejo-webhook-config
         key: provider.token
     webhook_secret:
       name: forgejo-webhook-config
       key: webhook.secret
   ```

4. In the Forgejo repository's **Settings → Webhooks**, add a **Forgejo** webhook
   with `POST`, `application/json`, and target URL `https://pac.rbl.lol`. Enable
   Push; pull request Opened, Reopened, Synchronized, Label updated, and Closed;
   and Issue Comments. Set the generated webhook secret.
5. Commit PipelineRun definitions under `.tekton/` in the Forgejo repository.
   The `default_branch` provenance in the `Repository` resource ensures that
   unmerged pull requests cannot alter the pipeline definition used by the
   controller.

> [!WARNING]
> Forgejo provider support in Pipelines-as-Code is technology preview, and the
> upstream controller does not validate Forgejo webhook signatures. Do not
> create
> `Repository` resources for untrusted repositories. Keep registration
> disabled, restrict Forgejo membership, and review PipelineRuns that might
> grant cluster or registry credentials.
