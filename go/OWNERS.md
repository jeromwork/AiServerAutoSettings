# Карта владения файлами (§4 go-port-plan.md, редакция 4)

Единственный автор каждого файла. После слияния владение передаётся по столбцу «Потом».

| Путь | Владелец | Потом (после слияния) |
|---|---|---|
| `go/go.mod`, `go.sum`, `internal/deps/*`, `internal/api/**` (вкл. `fake/`), `cmd/remoteagents/main.go`, `cmd/remoteagents/dispatch.go`, `check.sh`, `.golangci.yml`, `.gitignore`, `OWNERS.md`, `tools/versions.env`, заглушки пакетов | A0 | A0x (координатор) |
| `docs/contracts/{session,agent,journal-collect,slots-update-push,cleanup}.md` | D1, D2, D3, D4, D5 | D*r — пересверка после V2* |
| `third_party/singbox.lock.json` | L1a | — |
| `NOTICE.md` | L1b | R0 |
| `testdata/*` | L2 | L2b |
| `tools/bench/*` | B1 | F-задачи стенда |
| `internal/secret/*`, `cmd/remoteagents/dev_secret.go` | P1 | — |
| `internal/config/*` (+`remoteagents-2.schema.json`), `dev_config.go` | P2 | — |
| `internal/journal/*`, `dev_journal.go` | P3 | — |
| `internal/procs/*`, `dev_procs.go` | P4 | — |
| `internal/platform/shell_*.go`, `dev_shell.go` | P5a | — |
| `internal/platform/{platform,home,admin,browser,runas}_*.go`, `dev_platform.go` | P5b | — |
| `internal/platform/autostart_*.go` | P5c | — |
| `internal/platform/{ifaces,netwatch,foreignvpn}_*.go` | N4 | — |
| `internal/platform/lan_*.go` (DNS/NRPT/hosts) | N2 | — |
| `internal/singbox/{binary,run,clash}.go`, `dev_singbox.go` | P6a | — |
| `internal/singbox/render.go` | P6b | — |
| `internal/singbox/render_vpn.go` | N1a | — |
| `internal/singbox/render_lan.go` | N2 | — |
| `internal/webui/**`, `dev_webui.go` | P7 | — |
| `internal/supervise/*`, `dev_supervise.go` | P8 | — |
| `internal/update/*`, `dev_update.go` | P9 | — |
| `keys/release.pub` | R0 | — |
| `internal/cleanup/{cleanup,traces,run}.go` + `steps_linux.go`, `steps_darwin.go` | P10 | — |
| `internal/cleanup/steps_windows.go` | P10w | — |
| `tools/leftovers.sh`, `tools/leftovers.ps1` | P10t | — |
| `internal/agent/*`, `dev_agent.go` | P11 | — |
| `internal/forward/*`, `dev_forward.go` | P12 | — |
| `internal/channel/*`, `dev_channel.go` | P13 | — |
| `cmd/ra3/*` | P14 | — |
| `build.sh`, `cmd/remoteagents/winres/*` | P15a | — |
| `dev.sh`, `.air.toml` | P15b | — |
| `release.sh` | P15c | — |
| `internal/core/*` (кроме `vpnguard.go`), `cmd/remoteagents/main.go` | I1 (принимает у A0) | — |
| `internal/core/vpnguard.go` | N1b | — |
| `internal/install/*`, `tools/install.sh` | N3 | — |
| `tools/ra3-watch.ps1` | N0 | — |
| `tools/tun-box.sh` | N1c | — |
| `lab/release.sh` | V2a | — |
| `lab/ralab/{rounds,paths,singbox,app,link}.py`, `lab/server/ra_lab.py` | V2b | SRV1 (`ra_lab.py`) |
| `lab/ralab/{tun,bins,v2config}.py`, `lab/README.md`, `lab/CONFIG.md` | V2c | — |
| `lab/server/mcp_shim.py`, `ra_lab.py` (после V2b), репозиторная копия `server_node_catalog.py` | SRV1 | — |
| `docs/CONSTITUTION.md` | владелец (K1 — текст на утверждение) | — |

**Правила:**
- Все заглушки и пустые файлы-части создаёт A0, поэтому каждый владелец меняет только существующий у себя файл.
- **F-задачи** (исправления) получают файлы только того владельца, чьё замечание. Одновременно над одним файлом работает не больше одной задачи.
