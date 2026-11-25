FROM python:3.12-slim
RUN pip install --no-cache-dir "aiohttp>=3.9,<4" "PyJWT[crypto]>=2.8,<3" \
 && useradd -r -u 10001 notes && mkdir -p /audit && chown notes /audit
COPY --chmod=755 notes_api.py /app/notes_api.py
USER notes
EXPOSE 8080
CMD ["python", "-u", "/app/notes_api.py"]
