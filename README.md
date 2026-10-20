# Runyard

App de barra de menu do macOS para subir, parar e acompanhar os servidores locais de cada projeto.

## Instalação

```sh
./build.sh --install
```

## Registro de projetos

Cada projeto tem um arquivo em `~/.config/runyard/projects/<projeto>.json`:

```json
{
  "name": "meu-projeto",
  "path": "~/projects/meu-projeto",
  "services": [
    { "name": "docker", "command": "docker compose up" },
    { "name": "dev", "command": "pnpm dev" },
    { "name": "worker", "command": "composer worker", "env": { "APP_ENV": "local" } }
  ]
}
```

- `name` é opcional. O padrão é o nome do arquivo.
- `command` roda com `zsh -l` dentro de `path`.
- O app relê os registros toda vez que o menu abre.

## Logs

Cada serviço grava em `~/Library/Logs/runyard/<projeto>/<serviço>.log`.
