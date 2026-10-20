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
- Um serviço pode ter `path` próprio, absoluto ou relativo ao `path` do projeto. Use isso quando um projeto tem vários repositórios.
- O app relê os registros toda vez que o menu abre.

## CLI

O `./build.sh --install` cria o link `~/.local/bin/runyard`. A CLI fala com o app por um socket local e abre o app se ele estiver fechado.

```sh
runyard status [projeto]
runyard start <projeto> [serviço...]
runyard stop <projeto> [serviço...]
runyard restart <projeto> [serviço...]
runyard logs <projeto> <serviço> [-n linhas] [-f] [--path]
```

Sem serviço, `start`, `stop` e `restart` agem em todos os serviços do projeto. A CLI sai com código 1 se algum serviço não ficou rodando.

## Logs

Cada serviço grava em `~/Library/Logs/runyard/<projeto>/<serviço>.log`.
