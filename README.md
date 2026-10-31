# DummyBank walkthrough

This folder represents a bank and its installation of the Credit Workspace product.
The bank owns its data, identity provider, APIs and model-serving system. The same
product image can run for a different bank with a different installation profile.

The inventory and checks below were verified on 29 October 2026. All seeded customers
are synthetic. Database counts and configuration status are a snapshot, not live monitoring.

## 1. What is available

| Bank component | Available data or purpose |
|---|---|
| `core-db` | PostgreSQL bank database: 100 customers, 100 bureau reports, 280 accounts, 100 public-record entries and 200 exposure snapshots. |
| `customer-api` | OAuth2-protected HTTPS API exposing customer metrics from the bank database. |
| Warehouse source `exposure_dwh` | Read-only TLS connection to `risk.customer_exposure_daily`; exposes the latest `existing_exposure` for a customer. |
| `sso` | Bank Keycloak identity provider: browser sign-in, app roles and service-to-service tokens. |
| `models` | Bank model-serving API. Model files include `pd_pl_v1` and `uat_pd`; availability here is separate from registration/approval in the product. |

The product installation contains:

| Product component | Purpose |
|---|---|
| `engine-api` | Credit decision API and web console at <http://localhost:28080/console/>. |
| `engine-worker` | Background challenger jobs, outbox processing and configured exports. |
| `engine-db` | Product configuration, dictionary versions, model registrations, strategies, decisions and audit/evidence records. Separate from bank customer data. |
| `engine-migrate` | One-off product schema migration. A successful exited container is expected. |
| `dba-grants` | One-off runtime database grants. A successful exited container is expected. |

For this local lab, Docker with Compose runs these services and the product image
`ccp-engine:0.8.0`. The existing lab is already installed. Azure resources are deferred
until the final rollout stage.

## 2. Understand the existing customer API

The implementation is in [customer_api.py](bank/services/customer_api.py). Its endpoint is:

```http
GET https://customer-data.dummybank.internal:8443/v1/customers/{customer_id}/metrics
Authorization: Bearer <service access token>
```

This address belongs to the internal bank Docker network. The engine can reach it;
it is not a browser-facing localhost address. Use the console's API connection test
to exercise the deployed engine path.

The bank identity provider issues the token. The API requires audience
`customer-data-api` and role `customer-data:read`. The engine obtains its token with
OAuth2 client credentials; the client secret stays in the bank's mounted secret store.

For sample customer `DB0021`, field discovery returned these paths:

| Response path | Meaning | Detected type |
|---|---|---|
| `customer_id` | Source customer reference | text |
| `as_of` | Bureau observation date | date |
| `person.date_of_birth` | Input for an age transformation | date |
| `person.employment.type` | Bank employment code | text |
| `person.income.net_monthly` | Net monthly income | number |
| `scores.bureau` | Bureau score; some deliberately planted cases have no score | number in this sample |
| `affordability.dti` | Monthly debt payments divided by net monthly income | number |
| `affordability.max_affordable_amount` | Fixture affordability amount | number |
| `accounts.*.id` | Each account's identifier | text |
| `accounts.*.product` | Each account's product | text |
| `accounts.*.status` | Each account's status | text |
| `accounts.*.balance` | Each account's balance | number |
| `public_records.bankruptcy` | Bank code `Y` or `N` | text |

`*` means every element in a list. A dictionary mapping must explain how to combine
those elements, for example counting accounts or testing whether any status is
`WRITTEN_OFF`. API field availability does not itself create an approved engine variable.

## 3. How the product is configured to call it

The installed connection is in [engine/profile.template.yaml](engine/profile.template.yaml)
(`bash scripts/setup.sh` writes `generated/profile.yaml` from it with the effective ports):

```yaml
name: customer_api
provider: rest_api
required: true
options:
  url_template: https://customer-data.dummybank.internal:8443/v1/customers/{customer_ref}/metrics
  auth:
    type: oauth2_client_credentials
    token_url: https://sso.dummybank.internal:8443/realms/dummybank/protocol/openid-connect/token
    client_id: ccp-engine
    client_secret_secret_name: customer-api-client-secret
  ca_bundle_path: /mnt/secrets/ca.pem
  observed_at_field: as_of
```

These are connection settings and secret references, not secret values. `{customer_ref}`
is replaced by the sample/application customer ID. The CA verifies the bank's HTTPS
services. The API and token endpoints remain configurable per bank.

For a new installation, enter this source under **Platform setup → Data & models**,
validate/export the configuration package and deploy it through the bank release process.
The current installation already has this source and `exposure_dwh` deployed. **Current
configuration** shows what is running; the builder prepares a replacement package.

## 4. First hands-on test: the API connection

1. Open <http://localhost:28080/console/data-sources?source=customer_api> and sign in with
   the IT administrator account (`it.admin`). Use the locally provisioned credentials.
2. In **API connection test**, select deployed API **customer_api**.
3. Enter **DB0021** in **Sample customer ID**.
4. Click **Test connection**.
5. Expect **Connection verified**, **HTTP 200**, and 13 discovered field paths for this sample.
6. Repeat with **UNKNOWN_CUSTOMER**. Expect **HTTP 404** and the sample-not-found result.

The test works before models, products or approved dictionary mappings exist. It checks
the deployed authentication, certificates, request and JSON response, returning field
names/types. It does not make a credit decision. Optional fields may differ between samples.

Read-only verification from the running engine confirmed:

| Check | Result |
|---|---|
| Authenticated API read for `DB0021` | HTTP 200; 13 field paths |
| Same customer endpoint without a token | HTTP 401 |
| Authenticated request for an unknown customer | HTTP 404 |
| Warehouse authenticated read | `existing_exposure` available |
| Customer API and model-server health | HTTP 200 |

**Test a customer lookup / Fetch metrics** is a later operation that uses decision setup.
Begin with **API connection test** while building that setup.

## Setup, secrets and ports

* `bash scripts/setup.sh` creates the secrets and certificates once, and on every run writes the
  configuration for the effective ports (`ENGINE_PORT`, `SSO_PORT` from the environment, else
  `.env`, else 28080 / 18443) to `.env`, `generated/profile.yaml` and the Keycloak realm file.
  After changing a port, run it again and `docker compose up -d`; on an existing installation it
  also says which Keycloak client setting to update (Keycloak keeps its realm).
* `--force` creates new secrets and is refused while the installation's data exists: new
  passwords would lock out the databases and Keycloak, and a new customer-token key would cut
  customers off from their earlier decisions. To start over, delete the data first
  (`docker compose down -v`).
* Least privilege: the engine's API and worker mount `secrets/engine`; only `engine-migrate`
  mounts `secrets/engine-migration` (with the migration password). Each database mounts only its
  own certificate and key; the CA signing key (`secrets/ca`) is mounted nowhere.
* Databases and Keycloak restart with Docker; Keycloak keeps users, their IDs and signing keys
  on the `sso-data` volume.
* `python tools/verify.py` checks the installation end to end (9 checks); the bank's own
  evidence and IT review (setup guide step *checks*) stay with people.

## 5. What comes next

After the first test, use **Data dictionary** to discover the sample fields, choose the
variables, add transformations/code mappings/list aggregation, preview the results and
submit for another authorized user's approval. Then register/check/approve a model and
create/test/approve a product strategy.

At inspection time, dictionary v1 contained one variable and was `PENDING_APPROVAL`;
versions 2–5 were `DISCARDED`. There were no model registrations, strategy records or
decisions. Continue through the versioned workflow and preserve existing audit history.

The fixture includes planted test cases, described in
[generate_customers.py](bank/core-db/generate_customers.py):

- `DB0001`–`DB0003`: applicants under 18 at the fixture's reference date.
- `DB0004`–`DB0007`: a written-off account.
- `DB0008`–`DB0010`: bankruptcy.
- `DB0011`–`DB0015`: multiple accounts in arrears.
- `DB0016`–`DB0018`: missing bureau scores.
- `DB0019`–`DB0020`: deliberately old bureau reports.
- `DB0021`–`DB0100`: ordinary synthetic customers with varied scores, income and debts.

Decision outcomes depend on the product rules we actually configure. The fixture reference
date is 27 October 2026; the latest stored bureau/exposure date observed was 26 October.
Account for these dates when we configure freshness rules and test decisions later.

`tools/verify.py` is an existing automated configuration/decision exercise. Run it separately
from this guided walkthrough: its default mode creates configuration, submits approvals and
sends decisions, which would skip the steps we are learning together.
