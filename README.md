# remark-instance

Instancia self-hosted de [Remark42](https://remark42.com) para los comentarios de
**estrellaswebcam.com**. Corre en el VPS de Hetzner, detras del nginx del host.

```
navegador ─► estrellaswebcam.com (Astro)
                 │  rewrite server-side  /comments/*  ─►  https://comments.ewcam.co/*
                 ▼
           VPS · nginx host  (server_name comments.ewcam.co, TLS certbot)
                 │  proxy_pass  http://127.0.0.1:9081
                 ▼
           contenedor  ewcam-remark42   (SSL_TYPE=none, HTTP plano)
                 └─ volumen ./var  (BoltDB + avatares + imagenes + backups)
```

El navegador solo habla con `estrellaswebcam.com` → las cookies de Remark42 son
first-party y no las bloquea ningun navegador. `comments.ewcam.co` es publico y con
TLS porque el rewrite de Astro lo consume server-side, pero el cliente nunca lo
llama directo.

Este repo es **solo el backend**. El frontend (rewrite + widget) vive en el repo de
la web.

---

## Contenido

| Archivo | Para que |
|---|---|
| `compose.yaml` | Servicio `remark42`, imagen fija `v1.16.4`, bind `127.0.0.1:9081`. |
| `.env.example` | Plantilla de configuracion. |
| `.env` | Config real (gitignored). Contiene `SECRET` y `ADMIN_PASSWD`. |
| `deploy/comments.ewcam.co.nginx.conf` | vhost para el nginx del VPS. |
| `admin/index.html` | Panel de moderación estático (ver más abajo). |
| `VERSION` / `CHANGELOG.md` | Versión publicada del repo (tags `vX.Y.Z`). |
| `scripts/deploy.sh` | Despliegue/rollback en el VPS a un tag. |
| `scripts/seed-dev.sh` | Siembra la instancia local con comentarios de prueba. |
| `scripts/serve-admin-dev.py` | Proxy local para probar el panel sin nginx. |

---

## Despliegue en el VPS

### 1. DNS (GoDaddy)

Añadir registro:

```
Tipo  Nombre     Valor
A     comments   <IP_PUBLICA_DEL_VPS>
```

Comprobar: `dig +short comments.ewcam.co` → la IP del VPS.

### 2. Clonar

```bash
cd /opt   # o donde vivan los demas servicios
git clone git@github.com:Amarr-Asesores-SAS/remark-instance.git
cd remark-instance
```

### 3. Configurar `.env`

```bash
cp .env.example .env
```

Rellenar:

```bash
# clave de firma JWT
openssl rand -hex 32
# password admin (guardar en el gestor de secretos del equipo)
openssl rand -base64 18
```

Editar `.env` y poner esos valores en `SECRET` y `ADMIN_PASSWD`.
Revisar `TRUSTED_PROXY` (ver nota abajo).

### 4. Levantar el contenedor

```bash
docker compose up -d
docker compose logs -f          # ver arranque, Ctrl-C para salir
```

Verificacion local (aun sin nginx/TLS):

```bash
curl -s http://127.0.0.1:9081/api/v1/config?site=estrellaswebcam | head -c 200
```

Debe devolver JSON con `"auth_providers":["anonymous"]` y `"anon_vote":true`.

### 5. nginx del host

```bash
sudo cp deploy/comments.ewcam.co.nginx.conf /etc/nginx/sites-available/comments.ewcam.co
sudo ln -s /etc/nginx/sites-available/comments.ewcam.co /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 6. TLS

```bash
sudo certbot --nginx -d comments.ewcam.co
```

certbot añade el bloque `listen 443 ssl` y el redirect 80→443 al vhost.

### 7. Smoke test publico

```bash
curl -s https://comments.ewcam.co/api/v1/config?site=estrellaswebcam | head -c 200
```

---

## Operacion

### Logs

```bash
docker compose logs -f remark42
```

### Actualizar version

Editar el tag en `compose.yaml` (p. ej. `:v1.17.0`), luego:

```bash
docker compose pull
docker compose up -d
```

### Backups

Auto-backup diario dentro del contenedor → `var/backup/*.gz` (ultimos 15 dias).
Para respaldo externo, copiar el volumen completo:

```bash
tar czf remark-var-$(date +%F).tgz var/
```

Export manual completo (JSON):

```bash
source .env
curl -u admin:$ADMIN_PASSWD \
  "https://comments.ewcam.co/api/v1/admin/export?site=estrellaswebcam&mode=file" \
  -o export-$(date +%F).json.gz
```

### Borrar todos los datos (empezar de cero)

```bash
docker compose down
# var/ queda como root (uid del contenedor); borrar con un contenedor:
docker run --rm -v "$PWD/var:/v" alpine sh -c 'rm -rf /v/*'
docker compose up -d
```

---

## Moderacion (sin GUI)

Remark42 no tiene panel web. Se modera por la API con basic auth (`admin` + `ADMIN_PASSWD`).
`{url}` es la URL del hilo (la pagina de estrellaswebcam.com donde esta el comentario).

```bash
source .env
BASE=https://comments.ewcam.co
A="-u admin:$ADMIN_PASSWD"

# ultimos 50 comentarios del sitio (publico, sin auth)
curl -s "$BASE/api/v1/last/50?site=estrellaswebcam"

# borrar comentario
curl $A -X DELETE "$BASE/api/v1/admin/comment/{id}?site=estrellaswebcam&url={url}"

# pin / unpin
curl $A -X PUT "$BASE/api/v1/admin/pin/{id}?site=estrellaswebcam&url={url}&pin=1"

# hilo en solo-lectura
curl $A -X PUT "$BASE/api/v1/admin/readonly?site=estrellaswebcam&url={url}&ro=1"

# bloquear autor (ttl=0 = permanente). {userId} sale como "anonymous_xxx" en cada comentario
curl $A -X PUT "$BASE/api/v1/admin/user/{userId}?site=estrellaswebcam&block=1&ttl=0"

# ver bloqueados
curl $A "$BASE/api/v1/admin/blocked?site=estrellaswebcam"
```

Para clic-para-borrar hay un panel web: ver abajo.

---

## Panel de moderación (`/admin`)

Panel estático interno servido por el nginx del host en
`https://comments.ewcam.co/admin/`. Sin build, sin contenedor nuevo: es un solo
`admin/index.html` (JS vanilla) en este repo.

Qué hace:

- Escribes el `site` y trae los últimos N comentarios (`/api/v1/last/{max}`, sin auth).
- Botón **Cargar todo** → `GET /api/v1/admin/export?site=…&mode=stream` (con auth): baja
  el dump completo y lo pinta en la tabla.
- Por fila: borrar, pin/unpin, poner el hilo en solo-lectura (on/off), bloquear /
  desbloquear al autor (bloqueo permanente, `ttl=0`).
- Botón **Ver bloqueados** → `GET /api/v1/admin/blocked` con desbloqueo inline.
- Filtro por texto/autor y "ocultar borrados", en cliente.

### Auth (dos capas, una sola contraseña)

1. `nginx` protege `location /admin/` **y** `location ^~ /api/v1/admin/` con
   `auth_basic` contra `/etc/nginx/remark-admin.htpasswd`.
2. `nginx` reenvía el header `Authorization` a Remark42, que lo revalida contra
   `admin` + `ADMIN_PASSWD`.

Por eso el htpasswd **debe** ser `admin:<ADMIN_PASSWD del .env>`. Así el navegador
pide la contraseña una vez y la misma credencial vale para las llamadas de
moderación. (El panel además pide la contraseña por su cuenta si recibe un `401`,
como respaldo.)

### Deploy (una sola vez)

```bash
cd /opt/remark-instance   # ajusta a la ruta real del clon

# 1. htpasswd con la MISMA credencial que ADMIN_PASSWD (para que nginx pueda
#    reenviarla a Remark42)
sudo apt install -y apache2-utils
set -a; . ./.env; set +a
sudo htpasswd -bc /etc/nginx/remark-admin.htpasswd admin "$ADMIN_PASSWD"

# 2. vhost con las 3 location del panel (= /admin, /admin/, ^~ /api/v1/admin/)
sudo cp deploy/comments.ewcam.co.nginx.conf \
        /etc/nginx/sites-available/comments.ewcam.co
sudo nginx -t && sudo systemctl reload nginx
```

**Ojo con el bloque 443.** Si certbot ya editó el vhost in-place, el fichero
vivo tiene un `server { listen 443 ssl; ... }` que **no** está en el repo.
Copiar el fichero del repo encima deja las 3 `location` solo en el `:80`. Dos
salidas:

- pegar a mano las 3 `location` también dentro del `server` de `:443`, **o**
- `sudo certbot --nginx -d comments.ewcam.co` de nuevo → recrea el bloque 443
  desde el `:80` (que ya trae las location).

`root /opt/remark-instance;` en el vhost asume esa ruta de clon. Si vive en otra,
ajústalo. El usuario de nginx necesita lectura sobre `…/remark-instance/admin/`.

### Actualizar / hacer rollback

El panel y la infra se versionan con **tags** `vX.Y.Z` (ver
[Versionado](#versionado)). Para pasar el VPS a una versión:

```bash
cd /opt/remark-instance
./scripts/deploy.sh            # último tag
./scripts/deploy.sh v0.1.0     # una versión concreta (rollback igual)
```

`deploy.sh` hace `git fetch`, `checkout` del tag, regenera `admin/version.json`
(lo que muestra la cabecera del panel), levanta el contenedor solo si
`compose.yaml` cambió, valida y recarga nginx, y corre smoke tests contra
`https://comments.ewcam.co`.

### Smoke test

```bash
source .env
# 401 sin credencial
curl -s -o /dev/null -w '%{http_code}\n' https://comments.ewcam.co/admin/
# 200 con credencial
curl -s -o /dev/null -w '%{http_code}\n' -u admin:$ADMIN_PASSWD https://comments.ewcam.co/admin/
```

---

## Notas

- **`REMARK_URL`** es el unico valor acoplado al frontend: debe ser el dominio del
  sitio + subpath (`/comments`), no `comments.ewcam.co`. Si cambia el dominio del
  frontend o el prefijo del rewrite, se actualiza aqui y `docker compose up -d`.

- **`TRUSTED_PROXY`**: por defecto `172.16.0.0/12` (bridge docker). Confirmar con:

  ```bash
  docker network inspect ewcam-remark_default -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
  ```

  Si es otra subred (p. ej. `10.x`), ponerla en `.env`. Sin esto, el rate-limit y
  el "1 voto por IP" se aplican a la IP del gateway de docker, no a la del usuario.

- **Auth anonimo**: cada visitante elige un nombre (min. 3 caracteres: letras,
  numeros, `_`, espacios). No hay OAuth. El JWT va en cookie first-party.
  `POST /api/v1/comment` exige `?site=estrellaswebcam` en la query y header `X-XSRF-TOKEN`
  igual al claim `jti` del JWT — el cliente del frontend debe hacerlo (el widget
  oficial y el modulo de ejemplo ya lo hacen).

- **Nesting de respuestas**: el backend no limita profundidad. El limite de "1
  nivel" es decision del frontend (aplanar el arbol de `format=tree`).

---

## Versionado

Dos cosas distintas se versionan por separado:

| Qué | Cómo | Dónde se ve |
|---|---|---|
| **Este repo** (infra + panel) | tags git `vX.Y.Z` = contenido de `VERSION` | `git -C <clon> describe --tags` en el VPS; cabecera del panel (lee `admin/version.json`) |
| **Remark42** (backend) | tag de la imagen en `compose.yaml` | `docker compose images` |

Flujo para publicar una versión del repo:

```bash
# 1. subir VERSION y añadir la entrada en CHANGELOG.md (mover [Unreleased] -> [x.y.z])
$EDITOR VERSION CHANGELOG.md
git add VERSION CHANGELOG.md && git commit -m "🔖 chore: release v0.2.0"

# 2. tag anotado con el mismo número que VERSION
git tag -a v0.2.0 -m "v0.2.0"
git push origin main --follow-tags

# 3. en el VPS
./scripts/deploy.sh v0.2.0
```

Rollback = `./scripts/deploy.sh <tag-anterior>`. El VPS queda en *detached HEAD*
sobre el tag: es lo correcto, no hagas `git pull` ahí.

`admin/version.json` está en `.gitignore` — lo genera `deploy.sh` en el VPS, no
se commitea.
