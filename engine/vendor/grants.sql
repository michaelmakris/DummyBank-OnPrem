-- Least-privilege roles. Run once per database by the bank DBA (adjust role names).
-- ccp_migrator : owns the schema, runs migrations (used only by the migration job)
-- ccp_app      : API + worker runtime
-- ccp_monitor  : read-only dashboards / BI / Databricks federation
--
-- On Azure Database for PostgreSQL with Entra ID, create the login roles with
--   SELECT * FROM pgaadauth_create_principal('<managed-identity-name>', false, false);
-- On AWS RDS with IAM auth, add: GRANT rds_iam TO ccp_app;

CREATE ROLE ccp_migrator LOGIN;
CREATE ROLE ccp_app LOGIN;
CREATE ROLE ccp_monitor LOGIN;

CREATE SCHEMA IF NOT EXISTS ccp AUTHORIZATION ccp_migrator;
GRANT USAGE ON SCHEMA ccp TO ccp_app, ccp_monitor;

-- Run AFTER the first migration:
GRANT SELECT, INSERT ON ccp.decisions, ccp.shadow_evaluations TO ccp_app;
GRANT SELECT, INSERT, UPDATE ON ccp.shadow_jobs, ccp.outbox_events, ccp.idempotency_keys TO ccp_app;
GRANT USAGE ON SEQUENCE ccp.shadow_jobs_job_id_seq TO ccp_app;
-- campaigns (migration 0002) and results export (0003)
GRANT SELECT, INSERT, UPDATE ON ccp.campaigns, ccp.campaign_usage, ccp.export_cursors TO ccp_app;
GRANT SELECT, INSERT ON ccp.campaign_members, ccp.campaign_events TO ccp_app;
GRANT USAGE ON SEQUENCE ccp.campaign_events_event_id_seq TO ccp_app;
-- console-managed strategies (migration 0004); content frozen after DRAFT by trigger
GRANT SELECT, INSERT, UPDATE ON ccp.strategy_bundles TO ccp_app;
GRANT SELECT, INSERT ON ccp.strategy_events TO ccp_app;
GRANT USAGE ON SEQUENCE ccp.strategy_events_event_id_seq TO ccp_app;
GRANT SELECT, INSERT, UPDATE ON ccp.data_dictionaries TO ccp_app;
GRANT SELECT, INSERT ON ccp.dictionary_events TO ccp_app;
GRANT USAGE ON SEQUENCE ccp.dictionary_events_event_id_seq TO ccp_app;
GRANT SELECT, INSERT, UPDATE ON ccp.model_registry TO ccp_app;
GRANT SELECT, INSERT ON ccp.model_events TO ccp_app;
GRANT SELECT, INSERT ON ccp.installation_operations TO ccp_app;
GRANT USAGE ON SEQUENCE ccp.model_events_event_id_seq TO ccp_app;
-- data protection (migration 0007): the worker applies the retention period the DBA set in
-- ccp.retention_policy. erase_customer() is deliberately NOT granted: the DBA runs it as
-- ccp_migrator after DPO approval (see docs/compliance/gdpr.md).
GRANT EXECUTE ON FUNCTION ccp.apply_retention(integer) TO ccp_app;
GRANT SELECT ON ccp.retention_policy, ccp.privacy_events TO ccp_app, ccp_monitor;
-- field detection (migration 0008): field names and types per day, no personal data
GRANT SELECT, INSERT, UPDATE, DELETE ON ccp.source_responses, ccp.observed_fields TO ccp_app;
GRANT SELECT ON ccp.source_responses, ccp.observed_fields TO ccp_monitor;

GRANT SELECT ON ccp.v_champion_vs_shadow, ccp.v_shadow_coverage, ccp.v_daily_decisions,
               ccp.decisions, ccp.shadow_evaluations, ccp.shadow_jobs,
               ccp.v_campaign_performance, ccp.campaigns, ccp.campaign_usage TO ccp_monitor;
