"""End-to-end check of the dummy bank: does the credit engine, installed from the release and
configured ONLY through its public API (what the console does), decide correctly for the
bank's 100 customers? Python standard library only.

    python tools/verify.py            # configure (if needed) + decide for every customer
    python tools/verify.py --decide   # only send the decisions (configuration already done)

Steps, each as the person who would do it in the console (Keycloak logins from ./secrets):
  1  Setup guide shows what is missing                         (eva.viewer)
  2  Data sources: fetch one customer through both sources      (it.admin)
  3  Data dictionary v1: map the bank's fields                  (maria.risk -> nikos.approver)
  4  Model PD_PL@1 on the bank's model server, checked          (maria.risk -> nikos.approver)
  5  Product PL_STD with eligibility rules and data age limit   (maria.risk -> nikos.approver)
  6  The loan system asks for 101 decisions (100 + 1 unknown)   (los-system client)
  7  Planted cases end as expected, nothing errors, setup guide says ready
A report is written to reports/verify-report.md.
"""

from __future__ import annotations

import hashlib
import json
import math
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SECRETS = ROOT / "secrets"
ENGINE = "http://127.0.0.1:28080"
TOKEN_URL = "https://localhost:18443/realms/dummybank/protocol/openid-connect/token"
TLS = ssl.create_default_context(cafile=str(SECRETS / "tls" / "ca.pem"))
MODEL_FILE = ROOT / "bank" / "models" / "pd_pl_v1.json"
USERS = {"admin": "it.admin", "editor": "maria.risk", "approver": "nikos.approver",
         "viewer": "eva.viewer"}
RESULTS: list[tuple[str, bool, str]] = []


def secret(name: str) -> str:
    return (SECRETS / name).read_text(encoding="utf-8").strip()


def post_form(url: str, form: dict[str, str]) -> dict[str, Any]:
    req = urllib.request.Request(url, data=urllib.parse.urlencode(form).encode())
    with urllib.request.urlopen(req, context=TLS, timeout=15) as resp:
        return dict(json.loads(resp.read()))


_tokens: dict[str, tuple[float, str]] = {}


def token(who: str) -> str:
    """Keycloak access token: console users by password (test client), the loan system by
    client credentials. Cached until shortly before it expires."""
    if who in _tokens and _tokens[who][0] > time.time() + 20:
        return _tokens[who][1]
    if who == "los":
        out = post_form(TOKEN_URL, {"grant_type": "client_credentials", "client_id": "los-system",
                                    "client_secret": secret("los-client-secret")})
    else:
        out = post_form(TOKEN_URL, {"grant_type": "password", "client_id": "ccp-test-users",
                                    "username": USERS[who],
                                    "password": secret(f"password-{who}"), "scope": "openid"})
    _tokens[who] = (time.time() + out["expires_in"], out["access_token"])
    return out["access_token"]


def call(method: str, path: str, who: str, body: Any = None,
         headers: dict[str, str] | None = None) -> tuple[int, Any]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ENGINE + path, data=data, method=method, headers={
        "Authorization": f"Bearer {token(who)}", "Content-Type": "application/json",
        **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode(errors="replace")
        try:
            return exc.code, json.loads(text)
        except ValueError:
            return exc.code, text


def ok(method: str, path: str, who: str, body: Any = None) -> Any:
    status, out = call(method, path, who, body)
    if status >= 400:
        raise SystemExit(f"{method} {path} as {USERS.get(who, who)} -> {status}: {out}")
    return out


def check(name: str, passed: bool, detail: str = "") -> None:
    RESULTS.append((name, passed, detail))
    print(f"[{'PASS' if passed else 'FAIL'}] {name}{': ' + detail if detail else ''}")


# --------------------------------------------------------------------------- configuration
def v(name: str, label: str, kind: str, source: str, path: str, **kw: Any) -> dict[str, Any]:
    return {"name": name, "label": label, "kind": kind, "source": source, "path": path, **kw}


DICTIONARY = [
    v("bureau_score", "Bureau score", "numeric", "customer_api", "scores.bureau"),
    v("debt_to_income", "Debt-to-income ratio", "numeric", "customer_api", "affordability.dti"),
    v("affordability_cap", "Affordable amount", "numeric", "customer_api",
      "affordability.max_affordable_amount", unit="EUR"),
    v("existing_exposure", "Existing exposure", "numeric", "exposure_dwh", "existing_exposure",
      unit="EUR"),
    v("applicant_age", "Applicant age", "numeric", "customer_api", "person.date_of_birth",
      transform="age_years", unit="years"),
    v("employment_type", "Employment type", "categorical", "customer_api",
      "person.employment.type", categories=["SALARIED", "SELF_EMPLOYED", "PENSIONER", "OTHER"]),
    v("net_monthly_income", "Net monthly income", "numeric", "customer_api",
      "person.income.net_monthly", unit="EUR"),
    v("has_write_off", "Any written-off account", "boolean", "customer_api",
      "accounts.*.status", aggregate="any_in", match_values=["WRITTEN_OFF"]),
    v("accounts_in_arrears", "Accounts in arrears", "numeric", "customer_api",
      "accounts.*.status", aggregate="count_in",
      match_values=["ARREARS_30", "ARREARS_60", "ARREARS_90"]),
    v("bankruptcy_flag", "Bankruptcy on file", "boolean", "customer_api",
      "public_records.bankruptcy", true_values=["Y"], false_values=["N"]),
]

RULES = {"version": "DUMMYBANK_RULES_1", "rules": [
    {"rule_id": "KO_MINIMUM_AGE", "description": "Applicant younger than 18", "outcome": "DECLINE",
     "reason_code": "AGE_BELOW_MINIMUM",
     "when": [{"feature": "applicant_age", "op": "lt", "value": "18"}]},
    {"rule_id": "KO_WRITE_OFF", "description": "Any account written off", "outcome": "DECLINE",
     "reason_code": "WRITE_OFF_ON_FILE",
     "when": [{"feature": "has_write_off", "op": "eq", "value": True}]},
    {"rule_id": "KO_BANKRUPTCY", "description": "Bankruptcy on file", "outcome": "DECLINE",
     "reason_code": "BANKRUPTCY_ON_FILE",
     "when": [{"feature": "bankruptcy_flag", "op": "eq", "value": True}]},
    {"rule_id": "REF_ARREARS", "description": "Two or more accounts in arrears",
     "outcome": "REFER", "when": [{"feature": "accounts_in_arrears", "op": "ge", "value": "2"}]},
]}


def model_pd(m: dict[str, Any], x: dict[str, float]) -> str:
    z = m["intercept"] + sum(m["coefficients"][n] * x[n] for n in m["coefficients"])
    return f"{1 / (1 + math.exp(-z)):.6f}"


def model_body() -> dict[str, Any]:
    raw = MODEL_FILE.read_bytes()
    m = json.loads(raw)
    cases = [("typical", 650, 0.30, 8000), ("strong", 760, 0.08, 0), ("weak", 560, 0.45, 30000)]
    return {"model": {
        "model_id": "PD_PL", "version": "1",
        "artifact_digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
        "calibration_version": "CAL_2026_10", "target": m["target"], "horizon_months": 12,
        "inputs": [
            {"name": "bureau_score", "min_value": "300", "max_value": "900", "reference": "680",
             "reason_code": "LOW_BUREAU_SCORE", "description": "Bureau score"},
            {"name": "debt_to_income", "min_value": "0", "max_value": "5", "reference": "0.25",
             "reason_code": "HIGH_DEBT_TO_INCOME"},
            {"name": "existing_exposure", "min_value": "0", "max_value": "10000000",
             "reference": "10000", "reason_code": "HIGH_EXISTING_EXPOSURE"}],
        "test_cases": [{"name": n, "inputs": {"bureau_score": str(b), "debt_to_income": str(d),
                                              "existing_exposure": str(e)},
                        "expected_pd": model_pd(m, {"bureau_score": b, "debt_to_income": d,
                                                    "existing_exposure": e}),
                        "tolerance": "0.000001"} for n, b, d, e in cases]},
        "serving": {"provider": "mlflow_http", "options": {
            "url": "https://models.dummybank.internal:8443/models/pd_pl_v1/invocations",
            "token_secret_name": "model-api-token", "ca_bundle_path": "/mnt/secrets/ca.pem"}},
        "description": "Dummy bank personal-loan PD model, logistic, 12-month default"}


def configure() -> None:
    guide = ok("GET", "/v1/admin/setup", "viewer")
    todo = [s["id"] for s in guide["steps"] if s["status"] == "todo"]
    check("1 Setup guide lists what is missing", not guide["ready"] or not todo,
          f"to do: {', '.join(todo) or 'nothing'}")

    test = ok("POST", "/v1/admin/features/test", "admin", {"customer_ref": "DB0021"})
    check("2 Data sources: one customer through the customer API and the warehouse",
          bool(test.get("ok")), json.dumps(test)[:160])

    current = ok("GET", "/v1/admin/dictionary", "viewer")
    if current["current"] is None:
        created = ok("POST", "/v1/admin/dictionary", "editor",
                     {"variables": DICTIONARY, "note": "Dummy bank fields, first version"})
        ver = created["dictionary"]["version"]
        ok("POST", f"/v1/admin/dictionary/{ver}/submit", "editor")
        status, out = call("POST", f"/v1/admin/dictionary/{ver}/approve", "editor")
        check("3a Four-eyes: the editor cannot approve her own dictionary", status == 403,
              str(status))
        ok("POST", f"/v1/admin/dictionary/{ver}/approve", "approver")
    check("3 Data dictionary in effect", ok("GET", "/v1/admin/dictionary/variables", "viewer")
          ["version"] is not None)

    models = ok("GET", "/v1/admin/models", "viewer")["models"]
    if not any(m["ref"] == "PD_PL@1" and m["registered"]["status"] == "APPROVED"
               for m in models):
        if not any(m["ref"] == "PD_PL@1" for m in models):
            ok("POST", "/v1/admin/models", "editor", model_body())
        report = ok("POST", "/v1/admin/models/PD_PL/1/check", "editor")
        check("4a Model check against the bank's model server", bool(report.get("ok")),
              json.dumps(report)[:200])
        ok("POST", "/v1/admin/models/PD_PL/1/submit", "editor")
        ok("POST", "/v1/admin/models/PD_PL/1/approve", "approver")
    check("4 Model PD_PL@1 approved", True)

    products = ok("GET", "/v1/admin/products", "viewer")["products"]
    if not any(p["product_id"] == "PL_STD" and p["champion"] for p in products):
        draft = ok("POST", "/v1/admin/strategies/new-product", "editor", {
            "bundle_id": "PL-STD", "model_ref": "PD_PL@1", "note": "First product",
            "product": {"product_id": "PL_STD", "currency": "EUR", "min_amount": "500",
                        "max_amount": "15000", "amount_step": "50",
                        "allowed_tenors_months": [12, 24, 36, 48]}})["bundle"]
        base = f"/v1/admin/strategies/{draft['bundle_id']}/{draft['version']}"
        features = [{**f, **({"max_age_seconds": 180 * 86400}
                             if f["name"] == "bureau_score" else {})}
                    for f in draft["features"]]
        ok("PUT", base, "editor", {"policy_rules": RULES, "features": features,
                                   "valid_from": datetime.now(UTC).isoformat()})
        ok("POST", f"{base}/submit", "editor")
        ok("POST", f"{base}/approve", "approver")
        time.sleep(6)  # strategy caches refresh within seconds
    check("5 Product PL_STD live", any(p["product_id"] == "PL_STD" and p["champion"] for p in
                                       ok("GET", "/v1/admin/products", "viewer")["products"]))


# --------------------------------------------------------------------------- decisions
EXPECTED = {**{f"DB{n:04d}": ("DECLINE", "KO_MINIMUM_AGE") for n in range(1, 4)},
            **{f"DB{n:04d}": ("DECLINE", "KO_WRITE_OFF") for n in range(4, 8)},
            **{f"DB{n:04d}": ("DECLINE", "KO_BANKRUPTCY") for n in range(8, 11)},
            **{f"DB{n:04d}": ("REFER", "REF_ARREARS") for n in range(11, 16)},
            **{f"DB{n:04d}": ("REFER", None) for n in range(16, 21)},  # no / stale score
            "DB9999": ("REFER", None)}                                # unknown customer


def decide_all() -> None:
    counts: dict[str, int] = {}
    wrong, errors = [], []
    for cid in [f"DB{n:04d}" for n in range(1, 101)] + ["DB9999"]:
        status, out = call("POST", "/v1/credit-decisions", "los", {
            "application_id": f"app-{uuid.uuid4().hex[:10]}", "customer_ref": cid,
            "product_code": "PL_STD", "requested_amount": {"value": "5000.00", "currency": "EUR"},
            "requested_tenor_months": 24, "channel": "branch",
            "consent_references": ["bureau-consent-2026"]},
            headers={"Idempotency-Key": f"verify-{uuid.uuid4().hex}"})
        if status != 200:
            errors.append(f"{cid}: HTTP {status} {str(out)[:120]}")
            continue
        counts[out["status"]] = counts.get(out["status"], 0) + 1
        hits = [h["rule_id"] for h in out.get("policy_rules_hit") or []]
        if out["status"] == "ERROR":
            errors.append(f"{cid}: ERROR {out.get('reason_codes')}")
        if cid in EXPECTED:
            want, rule = EXPECTED[cid]
            if out["status"] != want or (rule and rule not in hits):
                wrong.append(f"{cid}: {out['status']} {out.get('reason_codes')} {hits}")
    check("6 101 decisions answered, none ERROR", not errors, "; ".join(errors[:5]))
    check("7 Planted cases (age, write-off, bankruptcy, arrears, missing/stale data, unknown "
          "customer) decided as expected, none approved", not wrong, "; ".join(wrong[:6]))
    print("   outcomes:", counts)
    guide = ok("GET", "/v1/admin/setup", "viewer")
    check("8 Setup guide: ready and the calling system connected",
          guide["ready"] and next(s for s in guide["steps"] if s["id"] == "go_live")["status"]
          == "done")


def main() -> int:
    if "--decide" not in sys.argv:
        configure()
    decide_all()
    failed = [r for r in RESULTS if not r[1]]
    out = ROOT / "reports"
    out.mkdir(exist_ok=True)
    lines = ["# Dummy bank end-to-end check", "", f"* Run: {datetime.now(UTC).isoformat()}",
             f"* Result: **{len(RESULTS) - len(failed)} / {len(RESULTS)} passed**", "",
             "| Check | Result | Detail |", "|---|---|---|"]
    lines += [f"| {n} | {'PASS' if p else 'FAIL'} | {d.replace('|', '/')[:200]} |"
              for n, p, d in RESULTS]
    (out / "verify-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} passed -> reports/verify-report.md")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
