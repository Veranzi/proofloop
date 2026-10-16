FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# Cloud Run sets PORT
# --no-access-log: app.middleware writes one structured line per request,
# and uvicorn's access log would include query strings.
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --no-access-log
