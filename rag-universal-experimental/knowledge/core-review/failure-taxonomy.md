# RAG Failure Taxonomy

## frontend_runtime_contract

- Cases: 829
- Severities: {"HIGH": 556, "UNKNOWN": 112, "MEDIUM": 80, "BLOCKER": 67, "LOW": 14}
- Owners to inspect: UIer SPA, Core Domain, Core HTTP Controllers, Control Plane Dispatcher, Documentation, Core Tests
- Top paths: bin/control_plane_job_dispatcher.php, uier-spa/src/stores/sandboxProvisioning.ts, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/views/admin/ControlPlaneView.vue, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, uier-spa/src/components/admin/provisioning/SandboxProvisionStepResult.vue, tests/run.php, uier/routes/web.php
- Example lessons: pr3-path-1, pr3-path-2, pr4-path-4, pr4-path-5, pr4-path-6

## transaction_atomicity

- Cases: 744
- Severities: {"HIGH": 518, "UNKNOWN": 79, "MEDIUM": 72, "BLOCKER": 69, "LOW": 6}
- Owners to inspect: UIer SPA, Core Domain, Documentation, Core HTTP Controllers, Control Plane Dispatcher, Sandbox Provisioning
- Top paths: app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, bin/control_plane_job_dispatcher.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/views/admin/ControlPlaneView.vue, uier-spa/src/stores/sandboxProvisioning.ts, uier/app/Http/Controllers/AdminSandboxProxyController.php, uier-spa/src/components/admin/provisioning/SandboxProvisionStepResult.vue, tests/run.php
- Example lessons: pr6-path-11, pr6-path-12, pr9-path-14, pr16-path-32, pr16-path-33

## test_contract

- Cases: 560
- Severities: {"HIGH": 370, "BLOCKER": 82, "UNKNOWN": 70, "MEDIUM": 30, "LOW": 8}
- Owners to inspect: Core Tests, UIer SPA, Core Domain, Core CLI/Workers, Application Source, Core HTTP Controllers
- Top paths: tests/run.php, uier/routes/web.php, tests/Unit/SandboxProvisioningServiceTest.php, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, tests/Unit/DataTables3ValueObjectsTest.php, tests/Unit/DataTables3RepositoriesTest.php, tests/Unit/DataTables3ServicesTest.php, bin/validate_plugin_quality.php
- Example lessons: pr4-path-3, pr12-path-20, pr12-path-21, pr16-path-27, pr16-path-28

## route_contract

- Cases: 463
- Severities: {"HIGH": 302, "UNKNOWN": 62, "BLOCKER": 52, "MEDIUM": 40, "LOW": 7}
- Owners to inspect: UIer SPA, Core HTTP Controllers, Plugin Platform, UIer router, Core Domain, Core Routes
- Top paths: uier/routes/web.php, routes/admin.php, tests/Feature/DataTables3RoutesFeatureTest.php, routes/modules/dt3-spreadsheet-internal.php, app/Http/Controllers/DataTables3Controller.php, plugins/data-tables-3/plugin.yaml, tests/run.php, uier/app/Http/Controllers/AdminSandboxProxyController.php
- Example lessons: pr4-path-4, pr4-path-6, pr5-path-8, pr5-path-9, pr5-path-10

## workflow_contract

- Cases: 447
- Severities: {"HIGH": 267, "UNKNOWN": 80, "MEDIUM": 53, "BLOCKER": 40, "LOW": 7}
- Owners to inspect: UIer SPA, Documentation, Core HTTP Controllers, Unknown, Core CLI/Workers, Core Domain
- Top paths: uier-spa/src/components/admin/provisioning/SandboxProvisionStepResult.vue, bin/control_plane_job_dispatcher.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/stores/sandboxProvisioning.ts, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, uier-spa/src/views/admin/ControlPlaneView.vue, uier/routes/web.php, uier-spa/src/components/admin/provisioning/SandboxProvisionStepDetails.vue
- Example lessons: pr12-path-19, pr12-path-20, pr16-path-27, pr16-path-32, pr16-path-33

## resource_lifecycle

- Cases: 435
- Severities: {"HIGH": 294, "BLOCKER": 64, "UNKNOWN": 54, "MEDIUM": 20, "LOW": 3}
- Owners to inspect: Core Domain, UIer SPA, Core CLI/Workers, Core HTTP Controllers, Plugin Platform, Core Tests
- Top paths: app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, tests/run.php, app/Http/Controllers/DataTables3Controller.php, bin/control_plane_job_dispatcher.php, app/Http/Controllers/DataTables3/WorkbookController.php, bin/validate_plugin_quality.php, bin/migrate.php, routes/admin.php
- Example lessons: pr5-path-7, pr5-path-9, pr5-path-10, pr6-path-11, pr6-path-12

## schema_form_contract

- Cases: 400
- Severities: {"HIGH": 251, "UNKNOWN": 69, "BLOCKER": 51, "MEDIUM": 24, "LOW": 5}
- Owners to inspect: Plugin Platform, UIer SPA, Core HTTP Controllers, Core Domain, Core CLI/Workers, Documentation
- Top paths: plugins/data-tables-3/plugin.yaml, uier/routes/web.php, app/Http/Controllers/DataTables3Controller.php, tests/run.php, routes/admin.php, app/Http/Controllers/DataTables3/WorkbookController.php, app/Domain/DataTables3/Service/SpreadsheetRuntime.php, Docs/plans/2026-04-24-data-tables-3-core-plugin-shell-packet-v1.md
- Example lessons: pr3-path-1, pr3-path-2, pr4-path-3, pr4-path-4, pr4-path-5

## rollout_control_plane

- Cases: 393
- Severities: {"HIGH": 281, "UNKNOWN": 50, "MEDIUM": 43, "BLOCKER": 12, "LOW": 7}
- Owners to inspect: Control Plane Dispatcher, UIer SPA, Documentation, Sandbox Provisioning, Control Plane, Core Domain
- Top paths: bin/control_plane_job_dispatcher.php, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/components/admin/provisioning/SandboxProvisionStepResult.vue, uier-spa/src/stores/sandboxProvisioning.ts, uier-spa/src/views/admin/ControlPlaneView.vue, uier/app/Http/Controllers/AdminSandboxProxyController.php, tests/Unit/SandboxProvisioningServiceTest.php
- Example lessons: pr5-path-7, pr5-path-9, pr5-path-10, pr16-path-36, pr16-path-37

## api_shape_contract

- Cases: 334
- Severities: {"HIGH": 208, "BLOCKER": 44, "UNKNOWN": 43, "MEDIUM": 32, "LOW": 7}
- Owners to inspect: Core Domain, UIer SPA, Core HTTP Controllers, Control Plane Dispatcher, Documentation, Core CLI/Workers
- Top paths: bin/control_plane_job_dispatcher.php, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/stores/sandboxProvisioning.ts, routes/admin.php, app/Domain/Tenancy/BrandedEmailService.php, tests/run.php, uier-spa/src/components/admin/provisioning/SandboxProvisionStepResult.vue
- Example lessons: pr12-path-16, pr12-path-17, pr12-path-18, pr12-path-21, pr12-path-22

## security_guard

- Cases: 248
- Severities: {"HIGH": 175, "MEDIUM": 34, "UNKNOWN": 26, "BLOCKER": 7, "LOW": 6}
- Owners to inspect: UIer SPA, Core HTTP Controllers, Plugin Platform, Documentation, UIer backend, Core Domain
- Top paths: uier/routes/web.php, bin/control_plane_job_dispatcher.php, uier-spa/src/stores/sandboxProvisioning.ts, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier/app/Http/Controllers/AdminSandboxProxyController.php, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php, tests/run.php, app/Http/Controllers/DataTables3Controller.php
- Example lessons: pr3-path-1, pr3-path-2, pr4-path-3, pr5-path-7, pr5-path-9

## owner_boundary

- Cases: 226
- Severities: {"HIGH": 153, "BLOCKER": 31, "UNKNOWN": 21, "MEDIUM": 17, "LOW": 4}
- Owners to inspect: Core HTTP Controllers, Core Domain, Core Tests, Plugin Platform, UIer SPA, UIer router
- Top paths: uier/routes/web.php, bin/control_plane_job_dispatcher.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, uier-spa/src/stores/sandboxProvisioning.ts, plugins/infraops-bff-adapter/Actions/Http/ControlPlaneProxySupport.php, app/Domain/EntityModels/AclResolver.php, app/Http/Controllers/DataTables3Controller.php, app/Domain/Tenancy/Provisioning/SandboxProvisioningService.php
- Example lessons: pr4-path-5, pr4-path-6, pr14-path-23, pr23-path-50, pr38-path-56

## audit_contract

- Cases: 158
- Severities: {"HIGH": 79, "BLOCKER": 41, "UNKNOWN": 19, "MEDIUM": 15, "LOW": 4}
- Owners to inspect: UIer SPA, Core CLI/Workers, Documentation, Core Tests, Application Source, Core Domain
- Top paths: routes/admin.php, Docs/specs/2026-04-20-sandbox-provisioning-wizard-spec-v1.md, bin/control_plane_job_dispatcher.php, uier-spa/src/components/reports/ScheduleDialog.vue, uier/routes/web.php, bin/worker_outbound_http.php, app/SystemTests/BigDataSubsystemVerifier.php, tests/Unit/AutoTriggerSelectionPlannerTest.php
- Example lessons: pr5-path-8, pr5-path-9, pr5-path-10, pr6-path-11, pr6-path-12

## general_review

- Cases: 15
- Severities: {"UNKNOWN": 8, "HIGH": 5, "BLOCKER": 2}
- Owners to inspect: Core CLI/Workers, Control Plane, Application Source, Documentation, Core HTTP Controllers, Plugin Platform
- Top paths: app/Domain/ControlPlane/NodeProvisioner.php, config/plugin_quality_policy.php, uier/plugins/devtools/backend/DevToolsController.php, uier/app/Http/Controllers/ApiEntityController.php, app/Domain/Insights/InsightFeedbackRepository.php, bin/migrate.php, app/Support/TenantMigration.php, bin/bootstrap_anvalt.php
- Example lessons: pr32-path-53, pr40-path-58, pr52-path-89, pr62-path-106, pr62-path-124

## build_portability

- Cases: 4
- Severities: {"UNKNOWN": 2, "BLOCKER": 2}
- Owners to inspect: Core Bootstrap, UIer SPA, Application Source, Unknown
- Top paths: bootstrap/autoload.php, uier/bin/preflight_core_integration.php, uier-spa/src/tests/views/admin/SettingsView.test.ts, uier-spa/src/stores/admin/admin-settings.ts
- Example lessons: pr70-path-254, pr70-path-255, pr80-path-1325, pr80-path-1335
