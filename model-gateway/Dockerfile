FROM python:3.12-slim
RUN pip install --no-cache-dir "aiohttp>=3.9,<4" "PyJWT[crypto]>=2.8,<3" \
 && useradd -r -u 10001 gateway && mkdir -p /audit && chown gateway /audit
COPY --chmod=755 gateway.py /app/gateway.py
USER gateway
EXPOSE 8080
CMD ["python", "-u", "/app/gateway.py"]
