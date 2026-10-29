"""Dummy bank PD model server (MLflow scoring protocol), the bank's data-science platform.

    POST /models/{name}/invocations   Authorization: Bearer <model API token>
    {"dataframe_split": {"columns": [...], "data": [[...]]}}

Each model is a JSON file in /models (a logistic regression: intercept + coefficients). The
server reports the sha256 of the file it scores with (`model_digest`), so the credit engine can
prove it uses the approved build. Contract: the credit engine's docs/model-contract.md.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import math
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException

MODELS = Path("/models")
TOKEN = Path("/run/secrets/model-api-token").read_text(encoding="utf-8").strip()
app = FastAPI(title="Dummy bank model serving")


def load(name: str) -> tuple[dict[str, Any], str]:
    path = MODELS / f"{name}.json"
    if not path.is_file() or path.parent != MODELS:
        raise HTTPException(404, "model not found")
    raw = path.read_bytes()
    return json.loads(raw), "sha256:" + hashlib.sha256(raw).hexdigest()


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/models/{name}/invocations")
async def invocations(name: str, body: dict[str, Any],
                      authorization: str = Header(default="")) -> dict[str, Any]:
    if not hmac.compare_digest(authorization.removeprefix("Bearer ").encode(), TOKEN.encode()):
        raise HTTPException(401, "invalid model API token")
    model, digest = load(name)
    frame = body.get("dataframe_split") or {}
    columns, rows = frame.get("columns", []), frame.get("data", [])
    coef: dict[str, float] = model["coefficients"]
    if sorted(columns) != sorted(coef):
        raise HTTPException(422, f"expected columns {sorted(coef)}, got {columns}")
    out = []
    for row in rows:
        x = dict(zip(columns, row, strict=True))
        z = model["intercept"] + sum(coef[n] * float(x[n]) for n in coef)
        pd = 1 / (1 + math.exp(-z))
        out.append({"calibrated_pd": round(pd, 6), "raw_score": round(z, 6),
                    "model_digest": digest,
                    "contributions": {n: round(coef[n] * (float(x[n]) - model["reference"][n]), 6)
                                      for n in coef}})
    return {"predictions": out}
