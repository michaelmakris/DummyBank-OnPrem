# The dummy bank's own services (customer API + model server). Not part of the credit engine.
FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi==0.115.6 "uvicorn==0.34.0" asyncpg==0.30.0 "pyjwt[crypto]==2.10.1"
WORKDIR /app
COPY customer_api.py model_server.py ./
USER 10001
