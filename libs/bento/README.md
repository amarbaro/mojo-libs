# mojo-bento

BentoML's serving core as a Mojo library: an epoll HTTP/1.1 server, typed JSON endpoints that answer byte for byte
like BentoML 1.4, health and Prometheus metrics, sd_notify, and streaming (BentoML's chunks or real SSE).

| Doc | Item |
|---|---|
| docs/plan.md | the plan and the lane contract |
| docs/server.md | B1 server and parser |
| docs/endpoints.md | B2 endpoints and error bodies |
| docs/ops.md | B4 health, metrics, systemd |
| docs/streaming.md | B6 streaming |

Gate: `tests/run.sh` (needs `.work/oracle-venv` with bentoml, h11, prometheus_client, httpx, httpx-sse).
