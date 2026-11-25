FROM python:3.12-slim
RUN pip install --no-cache-dir "aiohttp>=3.9,<4" "PyJWT[crypto]>=2.8,<3" \
 && useradd -r -u 10001 kbtool && mkdir -p /audit && chown kbtool /audit
COPY --chmod=755 kb_tool.py /app/kb_tool.py
USER kbtool
EXPOSE 8080
CMD ["python", "-u", "/app/kb_tool.py"]
