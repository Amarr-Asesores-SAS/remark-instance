# Changelog

Todos los cambios relevantes de este repo (infra + panel de moderación).
Formato [keepachangelog](https://keepachangelog.com/es-ES/1.1.0/),
versionado [SemVer](https://semver.org/lang/es/).

La versión desplegada en el VPS es el **tag** que tenga checked out
(`git -C <clone> describe --tags`). El panel la muestra en su cabecera leyendo
`admin/version.json` (generado por `scripts/deploy.sh`).

La versión de la imagen de Remark42 (`compose.yaml`) es aparte y se sube a mano.

## [Unreleased]

## [0.1.0] - 2026-09-02

### Added
- Infra base: `compose.yaml` (Remark42 `v1.16.4`, bind `127.0.0.1:9081`),
  `.env.example`, vhost `deploy/comments.ewcam.co.nginx.conf`.
- Runbook completo en `README.md` (despliegue VPS, TLS, backups, moderación).
- `CLAUDE.md` con la guía del repo.
- `scripts/seed-dev.sh`: siembra la instancia local con comentarios de prueba.
- Panel de moderación estático en `/admin` (`admin/index.html`, JS vanilla, sin
  build): lista los comentarios de un site vía `/api/v1/last` y
  `/api/v1/admin/export`; borrar, pin/unpin, hilo readonly y bloqueo de usuario
  por fila; vista de bloqueados; vista árbol que agrupa respuestas bajo su padre
  por `pid`, con colapso y filtro tree-aware.
- Wiring nginx del panel: `location /admin/` (estático) y
  `location ^~ /api/v1/admin/`, ambos tras `auth_basic` contra
  `/etc/nginx/remark-admin.htpasswd`; nginx reenvía la credencial a Remark42.
- `scripts/serve-admin-dev.py`: proxy local para probar el panel sin nginx.
- Versionado: `VERSION`, este `CHANGELOG.md`, `scripts/deploy.sh` (checkout de
  tag + `version.json` + `nginx -t`/reload + smoke test).

### Changed
- Site id canónico fijado a `estrellaswebcam` en `.env.example`, `README.md`,
  `CLAUDE.md` y el default del panel (antes `ewcam`, que no correspondía al
  contenedor).

[Unreleased]: https://github.com/Amarr-Asesores-SAS/remark-instance/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Amarr-Asesores-SAS/remark-instance/releases/tag/v0.1.0
