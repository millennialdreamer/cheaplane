# Container image used by MCP registries (Glama, etc.) to boot the server and
# introspect its tools. Nothing here is required for normal use — the usual path
# is still `bash setup.sh` on the host, or `pip install cheaplane`.
#
# The server speaks MCP over stdio and needs no network at start-up: delegated
# calls go to an OpenAI-compatible proxy at DELEGATE_BASE_URL, which is only
# contacted when the `delegate` tool is actually invoked. So `initialize` and
# `tools/list` succeed in an isolated container with no proxy running.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN pip install --no-cache-dir "mcp>=1.2"

COPY server.py ./

# stdio transport — run with `docker run -i --rm <image>`
CMD ["python", "server.py"]
