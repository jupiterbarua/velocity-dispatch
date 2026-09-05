

Velocity dispatch plan · MD
Velocity Dispatch — showcase project (updated 2026-09-05, round 5 continued: pull-not-build)
Status
Repo is live on GitHub: https://github.com/jupiterbarua/velocity-dispatch.git. CI has run for real multiple times now, surfacing genuine bugs (see below). Local verification is still not complete — Jupiter's test machine is a 2015 MacBook Air (dual-core, low RAM, Intel x86_64), which turned out to be the real constraint the whole time, not just the release profile or missing cache mounts. Decision this round: stop trying to make local compilation fast enough on that hardware, and instead have CI publish tested images to GHCR so Jupiter can docker compose pull instead of building. See earlier round entries further down for architecture, requirements/CI-CD/SQS docs, monitoring, and Week 1 scoping — all still accurate.

Standing process instruction (do not forget)
Jupiter: "i do not want you write the project at once, we will go agile development." Small discussed increments, confirm non-trivial design direction before implementing. Governs the whole project.

What happened this round — chasing real build/CI failures one at a time
Continuing directly from the round-5 entry below (GitHub push, first CI failure, the CoreError: Eq bug, the slow-release-profile diagnosis). In order, since then:

fmt + clippy still failing after the Eq fix — Jupiter pasted the next real compiler complaint: services/dispatch-api/src/error.rs line 14 exceeded rustfmt's 100-char width with an unwieldy nested generic type (aws_sdk_sqs::error::SdkError<aws_sdk_sqs::operation::send_message::SendMessageError>). Checked proactively and found the same type duplicated in services/dispatch-api/src/sqs.rs line 19 too (would have been the next fmt failure in the queue). Fixed both with a pub(crate) type SqsSendError = ... alias in error.rs, imported into sqs.rs — cleaner than letting rustfmt hard-wrap the generic across lines. Confirmed dispatch-worker's equivalent EventBridge publisher uses anyhow::Result<()> instead, so it was never at risk of the same issue.
Local docker compose up --build still took 22+ minutes even after switching to the debug-profile dev stage — the real cause: dev and the original builder (release) stage are separate Docker build stages that don't share a filesystem, so each one independently re-downloaded this workspace's entire dependency tree from crates.io from scratch (including the large AWS SDK crates) — a structural gap I introduced when adding the dev stage, not a hardware problem by itself. Fixed with BuildKit cache mounts (RUN --mount=type=cache,target=/usr/local/cargo/registry + target=/app/target, sharing=locked) on every cargo chef cook/cargo build step in both dispatch-api and dispatch-worker Dockerfiles. Gotcha this introduced: a cache mount's contents don't persist into the built image layer, so each build now cp's its binary out to a plain path (/app/dispatch-api-bin etc.) before the RUN ends, and the downstream COPY --from= lines were updated to match.
Turning point: Jupiter revealed the actual hardware — a 2015 MacBook Air. Realistically can't compile this dependency graph quickly no matter how much the Dockerfile is optimized. Jupiter proposed the fix himself: publish images to a registry and pull instead of building. Implemented:
ci.yml gained a publish-images job (needs [lint, test], only fires on push to main) that logs into GHCR with the repo's built-in GITHUB_TOKEN (no new secrets) and pushes the already-tested runtime target for all three services, tagged :latest and :${{ github.sha }}, for both linux/amd64 and linux/arm64 (buildx cross-compiles the arm64 variant on GitHub's amd64 runners) — so the same pulled image works regardless of what machine someone's on.
docker-compose.yml: both dispatch-api/dispatch-worker now set both image: (the GHCR tag, what docker compose pull fetches) and build: (still there for anyone with capable hardware who wants to build from source) — Compose's normal behavior means docker compose pull && docker compose up needs zero local compilation, while docker compose up --build still works for source changes.
README's "Running it locally" now leads with the pull path, build path second.
Not yet done, flagged in SPRINT_LOG.md: the GHCR package will be private by default on first push — Jupiter needs to either flip it to public in the repo's Packages settings, or docker login ghcr.io with a PAT (read:packages scope) before docker compose pull will work. Haven't confirmed which he'll choose.
All changes bracket/YAML-validated (0 mismatches; docker-compose.yml/ci.yml both parse via yaml.safe_load) and repackaged/delivered.

Sandbox caveat
Still no crates.io/npm/pip/terraform-registry access here — verification continues to depend on Jupiter pasting real compiler/CI output, or (going forward) GHCR image pulls succeeding. This is working well as a pattern — lean on it.

Open items / do not forget
GHCR package visibility decision pending — package will be private until Jupiter makes it public or authenticates. Follow up next time this comes up.
test and terraform fmt + validate CI jobs' failures are still unresolved — root cause never seen (GitHub hides authenticated logs from me). Still waiting on Jupiter to paste that log text or run the equivalent commands locally/via a capable machine.
Local Week 1 verification (scripts/week1_smoke_test.sh) still hasn't completed successfully — next step once the GHCR package is pullable: docker compose pull dispatch-api dispatch-worker && docker compose up, then the smoke test.
docs/RESUME_BULLETS.md removal-from-GitHub request — walked through git rm --cached + .gitignore, flagged the two README references that would 404 once removed, Jupiter hasn't confirmed whether to strip those yet.
FR-12 (delivery completion) — still undecided (manual endpoint vs geofence-driven). Do not implement without asking.
Open question: should a future "delivered" transition also publish an EventBridge event? Not decided.
Company research (Scalable Capital, Nelly Solutions, MOIA, Kraken, Keyrock) — captured in round-2 entry further down, still valid.
Roadmap (only once Jupiter confirms): Week 2 = EventBridge + Lambda integration; Week 3 = Terraform AWS deploy re-validation; Week 4 = observe monitoring against a real deployment.
Round 5 entry (2026-09-04 — first real compiler/CI contact), preserved for history
GitHub push hit a stray SSH remote (git remote set-url fixed it, unrelated to code). First real CI run failed 3/4 jobs. Found and fixed a genuine bug from pasted fmt + clippy output: CoreError derived Eq but has an f64-holding variant, and f64 isn't Eq (NaN breaks reflexivity) — dropped Eq, kept PartialEq. Separately, local docker compose up --build took 1282+ seconds compiling a trivial crate — traced to Cargo.toml's deliberate [profile.release] (lto = true, codegen-units = 1, chosen for a faster/smaller production binary) making a from-scratch release compile very slow, worsened by the AWS SDK dependency graph. Jupiter asked to let the build finish once, then Ctrl+C'd anyway, so added a debug-profile dev build stage to both service Dockerfiles for local use, with docker-compose.yml targeting it — and had to explicitly pin target: runtime in ci.yml/deploy.yml since neither previously specified a target and would have silently started shipping the new dev stage otherwise. Also renamed a stage in dispatch-notify-lambda/Dockerfile for naming consistency.

Round 4 entry (2026-09-04 — Week 1 restart/scoping), preserved for history
Jupiter said: "Now, with first week. lets start over. so this common, consumer and producer all are different service that independently works." Clarified into: keep existing code, reframe as sprints; Week 1 scope = common + producer + consumer running locally only, explicitly excluding Lambda/EventBridge/Terraform/monitoring even though those already exist in the repo. Defined "independently working service" as 4 criteria in new docs/SPRINT_LOG.md. Found and fixed a real violation: dispatch-worker depended on dispatch-api's Docker health check because only dispatch-api ran migrations — fixed by having both services run sqlx::migrate! (safe via Postgres advisory lock) and removing the compose dependency. Wrote scripts/week1_smoke_test.sh as the runnable acceptance check.

Round 3 entry (2026-08-19 — monitoring/logging), preserved for history
Surfaced the FR-12 gap (delivery completion never implemented) while discussing driver status/geofencing — documented, not built, pending a design decision. Built real /health readiness check, CloudWatch EMF business metrics, log-based error alarms, and a CloudWatch dashboard, all in one round after Jupiter multi-selected all four options.

Round 2 entry, preserved for history
Full requirements analysis, AWS CI/CD-to-Fargate pipeline (incl. GitHub OIDC IAM role fix), SQS implementation deep-dive doc, deployment guide. Company research: Scalable Capital best overall stack fit; Nelly Solutions (Berlin healthtech) strong fit; MOIA closest thematic match; Keyrock/Kraken assessed as a stretch given no trading-domain background.



