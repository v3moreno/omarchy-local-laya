"""local-laya server: laya.serve + a batch endpoint.

`python -m laya.serve` exposes only POST /v1/systemone (one state per call).
This module builds the same app and adds POST /v1/systemone/batch:

    {"states": ["doc1", "doc2", ...], "questions": {...}, "model": "english?"}
    -> {"results": [<per-state answer objects>], "model": ..., "usage": ...}

Batching packs all states' question rows into shared forward passes — on GPU
that's several times faster per decision than N sequential calls.

Run: same env as laya-serve (LAYA_DEVICE/LAYA_PORT/LAYA_PRELOAD/...).
"""

import asyncio
import os
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, Optional


MAX_STATES = 64
MAX_STATE_CHARS = int(os.environ.get("LAYA_MAX_STATE_CHARS", "262144"))


def create_app():
    import hmac
    from contextlib import asynccontextmanager

    from fastapi import FastAPI, Header, HTTPException, Request
    from laya.serve import build_router

    router = build_router()
    api_key = os.environ.get("LAYA_API_KEY") or None
    pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="laya-infer")
    gate: Optional[asyncio.Lock] = None

    @asynccontextmanager
    async def lifespan(_app):
        try:
            yield
        finally:
            pool.shutdown(wait=True, cancel_futures=True)

    app = FastAPI(title="local-laya", summary="Laya decisions + batch", lifespan=lifespan)
    expected_auth = ("Bearer " + api_key).encode("utf-8", "surrogateescape") if api_key else b""

    def check_auth(authorization: Optional[str]) -> None:
        if api_key is None:
            return
        if not hmac.compare_digest((authorization or "").encode("utf-8", "surrogateescape"), expected_auth):
            raise HTTPException(status_code=401, detail="invalid or missing bearer token")

    @app.get("/health")
    def health() -> Dict[str, Any]:
        return {"status": "ok", "loaded": router.loaded, "device": os.environ.get("LAYA_DEVICE") or "auto"}

    @app.post("/v1/systemone")
    async def systemone(request: Request, authorization: Optional[str] = Header(default=None)):
        nonlocal gate
        check_auth(authorization)
        body = await request.json()
        if not isinstance(body, dict) or "questions" not in body:
            raise HTTPException(status_code=400, detail="body must be an object with a 'questions' field")
        if gate is None:
            gate = asyncio.Lock()
        try:
            async with gate:
                loop = asyncio.get_running_loop()
                return await loop.run_in_executor(
                    pool, lambda: router.predict(body.get("state"), body["questions"], model=body.get("model")))
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(status_code=500, detail="inference failed")

    @app.post("/v1/systemone/batch")
    async def systemone_batch(request: Request, authorization: Optional[str] = Header(default=None)):
        nonlocal gate
        check_auth(authorization)
        body = await request.json()
        # two shapes: {"requests": [{state, questions, model?}, ...]} or
        # {"states": [...], "questions": {...}} (same questions for all states)
        requests = body.get("requests")
        if requests is None:
            states, questions = body.get("states"), body.get("questions")
            if not isinstance(states, list) or not isinstance(questions, dict):
                raise HTTPException(status_code=400, detail="body needs 'requests' or 'states' + 'questions'")
            requests = [{"state": s, "questions": questions} for s in states]
        if not requests or len(requests) > MAX_STATES:
            raise HTTPException(status_code=400, detail=f"batch must have 1..{MAX_STATES} requests")
        for r in requests:
            if not isinstance(r, dict) or "state" not in r or "questions" not in r:
                raise HTTPException(status_code=400, detail="each request needs 'state' and 'questions'")
            if len(r["state"] if isinstance(r["state"], str) else str(r["state"])) > MAX_STATE_CHARS:
                raise HTTPException(status_code=413, detail=f"state too large (> {MAX_STATE_CHARS} chars)")
        batch_size = body.get("batch_size")
        if gate is None:
            gate = asyncio.Lock()
        try:
            async with gate:
                loop = asyncio.get_running_loop()
                results = await loop.run_in_executor(
                    pool,
                    lambda: router.predict_batch(
                        requests, batch_size=batch_size if isinstance(batch_size, int) else None),
                )
            return {"results": list(results), "count": len(requests)}
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(status_code=500, detail="inference failed")

    return app


def main() -> None:
    import uvicorn

    uvicorn.run(
        create_app(),
        host=os.environ.get("LAYA_HOST", "0.0.0.0"),
        port=int(os.environ.get("LAYA_PORT", "8123")),
        log_level=os.environ.get("LAYA_LOG_LEVEL", "info"),
    )


if __name__ == "__main__":
    main()
