# Будущее развёртывание серверных частей

```json
"deployment": {"method": "docker", "dockerfile": "server/docker/Dockerfile"}
```

`method` по умолчанию `host`. Сейчас EXE и сервер отказывают на `docker` до
развёртывания: «Развёртывание docker ещё не поддерживается». Поля `image` и
`dockerfile` сохраняются и экспортируются; произвольные команды не исполняются.
Этот Dockerfile — скелет формата, не готовый образ установки.

Нужно отдельно спроектировать сохранение секретов/томов, SSH, системную сеть,
OpenVPN и userspace Tailscale, health checks и обновление/откат. Стенд в
`server/tests/autodeploy` имитирует host VPS с systemd; это другой Dockerfile.
