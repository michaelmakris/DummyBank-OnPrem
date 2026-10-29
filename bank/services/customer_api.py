"""Dummy bank customer-data API (the bank's system, not part of the credit engine).

    GET /v1/customers/{customer_id}/metrics      Authorization: Bearer <OAuth2 access token>

Only callers whose token (issued by the bank's Keycloak) carries the role customer-data:read
and the audience customer-data-api get data. HTTPS only, data read from the core database over
verified TLS. 404 when the customer does not exist.
"""

from __future__ import annotations

import os
import ssl
from contextlib import asynccontextmanager
from typing import Any

import asyncpg
import jwt
from fastapi import Depends, FastAPI, Header, HTTPException

ISSUER = os.environ["OIDC_ISSUER"]
JWKS = jwt.PyJWKClient(os.environ["OIDC_JWKS_URL"],
                       ssl_context=ssl.create_default_context(cafile=os.environ["CA_FILE"]))
pool: asyncpg.Pool | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):  # type: ignore[no-untyped-def]
    global pool
    tls = ssl.create_default_context(cafile=os.environ["CA_FILE"])
    with open("/run/secrets/core-api-password", encoding="utf-8") as f:
        password = f.read().strip()
    pool = await asyncpg.create_pool(host=os.environ["DB_HOST"], database="core",
                                     user="customer_api", password=password, ssl=tls,
                                     min_size=1, max_size=5)
    yield
    await pool.close()


app = FastAPI(title="Dummy bank customer data", lifespan=lifespan)


def caller(authorization: str = Header(default="")) -> dict[str, Any]:
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(401, "missing bearer token")
    try:
        key = JWKS.get_signing_key_from_jwt(token)
        claims: dict[str, Any] = jwt.decode(token, key.key, algorithms=["RS256"],
                                            audience="customer-data-api", issuer=ISSUER)
    except jwt.PyJWTError as exc:
        raise HTTPException(401, f"invalid token: {type(exc).__name__}") from None
    if "customer-data:read" not in claims.get("roles", []):
        raise HTTPException(403, "role customer-data:read required")
    return claims


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/customers/{customer_id}/metrics")
async def metrics(customer_id: str, _: dict[str, Any] = Depends(caller)) -> dict[str, Any]:
    assert pool is not None
    async with pool.acquire() as db:
        c = await db.fetchrow("SELECT * FROM core.customers WHERE customer_id = $1", customer_id)
        if c is None:
            raise HTTPException(404, "customer not found")
        b = await db.fetchrow("SELECT * FROM core.bureau_reports WHERE customer_id = $1",
                              customer_id)
        accounts = await db.fetch("SELECT account_id, product, status, balance FROM "
                                  "core.accounts WHERE customer_id = $1 ORDER BY account_id",
                                  customer_id)
        bankrupt = await db.fetchval("SELECT bankruptcy FROM core.public_records "
                                     "WHERE customer_id = $1", customer_id)
    income, debt = c["net_monthly_income"], c["monthly_debt_payments"]
    return {
        "customer_id": customer_id,
        "as_of": b["as_of"].isoformat() if b else None,
        "person": {"date_of_birth": c["date_of_birth"].isoformat(),
                   "employment": {"type": c["employment_type"]},
                   "income": {"net_monthly": float(income)}},
        "scores": {"bureau": b["bureau_score"] if b else None},
        "affordability": {"dti": round(float(debt / income), 4),
                          # what the customer can still repay per month, times 24 months
                          "max_affordable_amount": round(float(max(income * 35 / 100 - debt, 0)
                                                               * 24), 2)},
        "accounts": [{"id": a["account_id"], "product": a["product"], "status": a["status"],
                      "balance": float(a["balance"])} for a in accounts],
        "public_records": {"bankruptcy": "Y" if bankrupt else "N"},
    }
