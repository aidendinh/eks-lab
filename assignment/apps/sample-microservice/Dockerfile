FROM python:3.13-alpine3.22

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

RUN addgroup -g 2000 appgroup \
    && adduser -D -H -u 10001 -G appgroup appuser

WORKDIR /app
COPY --chown=10001:2000 app.py /app/app.py

USER 10001:2000
EXPOSE 8080

ENTRYPOINT ["python", "/app/app.py"]

