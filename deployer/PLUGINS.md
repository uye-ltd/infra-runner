# Legacy plugin descriptors retired

The poller does not load `*.plugin` files, Compose overlays, environment files, or hook scripts. It reads only `/etc/uye-poller/targets.json`, an Ansible-managed public list of images and exact signing identities. It verifies signatures for observation and exposes `/health`; it cannot request a deployment.

New managed services are registered in the root-owned target table and fixed Compose manifests in `infra-ansible/roles/uye_deploy/`. The host executor obtains `main` independently, checks fast-forward history, the SHA tag, `latest`, the image revision label and the exact cosign identity, then pulls by digest. A change to the target table, Compose spec, Vault policies, tenant SQL or tenant descriptors requires an Ansible run. The executor never executes scripts from server checkouts.

The old `.infra-runner.plugin`, `deploy/*.plugin`, and `docker-compose.infra-runner.yml` files in sibling repositories are deprecated data. Do not mount them into the poller or add them to `COMPOSE_FILE`.
