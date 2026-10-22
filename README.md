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
    { "name": "dev", "command": "pnpm dev", "restart": true },
    { "name": "worker", "command": "composer worker", "env": { "APP_ENV": "local" } }
  ]
}
```

- `name` é opcional. O padrão é o nome do arquivo.
- `command` roda com `zsh -l` dentro de `path`.
- Um serviço pode ter `path` próprio, absoluto ou relativo ao `path` do projeto. Use isso quando um projeto tem vários repositórios.
- `url` é opcional. Sem ele, o app procura a primeira URL local no log da execução atual e mostra o botão de abrir no navegador.
- `port` é opcional. Sem ele, o app usa `env.PORT`, a porta de `url` ou a porta da URL achada no log da última execução.
- `restart: true` sobe o serviço de novo 2 segundos depois de uma queda. O app desiste depois de 5 quedas em 1 minuto.
- O app relê os registros toda vez que o menu abre.

## Avisos

- O app manda uma notificação quando um serviço encerra com erro. A notificação tem os botões "Reiniciar" e "Ver log".
- Antes de subir um serviço pelo menu, o app confere se a porta dele está livre. Se estiver ocupada, ele mostra quem usa a porta e oferece encerrar esse processo. Pela CLI, o app só grava um aviso no log.

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

A janela de logs (⌘L no menu) acompanha o log de cada serviço. Ela tem busca (⌘F), filtro por nível (tudo, avisos, erros) e um formatador que mostra as cores do comando, destaca níveis, HTTP e URLs, e organiza linhas JSON. O app exporta `FORCE_COLOR=1` e `CLICOLOR_FORCE=1` para os comandos gerarem cor. A CLI tira as cores quando a saída não é um terminal.
