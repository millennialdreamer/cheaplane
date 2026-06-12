#!/usr/bin/env python3
"""End-to-end probe: connect to server.py over the real MCP protocol (stdio),
handshake -> list tools -> call delegate with auto-routing, and print what the
cheap model returns. Verifies the whole "main agent -> MCP tool -> cheap model"
chain actually works."""
import os
import sys
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Launch the server with the current interpreter (this probe's venv python): portable, no hard-coded absolute path
PY = sys.executable
SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")


async def main():
    # Pass our env through so DELEGATE_* overrides apply to the spawned server too
    # (the MCP SDK only forwards a minimal default env unless told otherwise).
    params = StdioServerParameters(command=PY, args=[SERVER], env=dict(os.environ))
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("1. handshake OK; tools exposed =", [t.name for t in tools.tools])

            print("2. calling delegate() with auto-routing: ask the cheap model for one short line…")
            r = await session.call_tool(
                "delegate",
                {"task": "In one short sentence, tell me which model you are."},
            )
            text = r.content[0].text if r.content else "(empty)"
            print("   cheap model says >>>", text[:400])

            ok = not text.startswith("[delegate-error]") and text.strip()
            print("\n3. end-to-end result:", "✅ chain works (main → MCP → cheap model → back)" if ok else "❌ failed, see error above")


if __name__ == "__main__":
    asyncio.run(main())
