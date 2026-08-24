# Agentbox CLI — instrukcja

CLI korzysta z tej samej biblioteki co aplikacja. Uruchom pomoc poleceniem:

```bash
swift run agentbox --help
```

Gotową binarkę release można wywoływać jako `.build/release/agentbox`. Zmienna `SKILLBOX_HOME` wskazuje inną bibliotekę:

```bash
SKILLBOX_HOME="$HOME/Documents/AgentboxData" swift run agentbox list
```

## Skille

```bash
agentbox list
agentbox add ./folder-skilla [--id nazwa]
agentbox add https://github.com/user/repo.git [--path skills] [--branch main] [--id nazwa]
agentbox tag nazwa-skilla seo audit
agentbox update nazwa-skilla
agentbox update --all
```

`add` kopiuje lokalny skill albo importuje wszystkie znalezione `SKILL.md` z Git. `tag` zastępuje listę tagów wskazanego skilla. `update` działa dla skilli pochodzących z Git.

## Projekty

```bash
agentbox project list
agentbox project add sklep /pełna/ścieżka/do/sklepu --tools claude,codex,opencode
agentbox project set sklep --skills seo-audit,docx --tags seo
```

`project set` ustawia bezpośrednie skille i dynamiczne tagi. Pusta opcja usuwa wcześniejsze przypisania danego typu.

## Synchronizacja skilli

```bash
agentbox sync project sklep
agentbox sync project sklep --dry-run
agentbox sync global claude --skills seo-audit,docx --tags seo
agentbox sync global codex --skills docx --dry-run
```

`--dry-run` pokazuje liczbę planowanych kopii i usunięć bez zapisu. CLI rozdziela synchronizację skilli i MCP; GUI wykonuje je razem jako transakcję.

## MCP

```bash
agentbox mcp list

agentbox mcp server add context7 \
  --command npx \
  --args=-y,@upstash/context7-mcp \
  --env TOKEN=TOKEN \
  --tags seo,docs

agentbox mcp server add senuto \
  --url https://mcp.senuto.com/mcp \
  --headers Authorization=SENUTO_TOKEN \
  --tags seo

agentbox mcp assign sklep --servers context7 --tags seo
agentbox mcp preview sklep
agentbox mcp sync sklep
```

`mcp assign` zastępuje bezpośrednie serwery i tagi MCP projektu. Wartości `--env` i `--headers` są odwołaniami do zmiennych systemowych, nie lokalnymi sekretami. Pełną klasyfikacją sekretów istniejącego MCP zarządza obecnie interfejs aplikacji.

## Backup Git

```bash
agentbox backup
agentbox backup --message "Aktualizacja konfiguracji"
agentbox backup --remote git@github.com:user/agentbox-backup.git
```

Backup Git nie zawiera projektów, lokalnych ścieżek, sekretów ani folderu `backups/`. Pełny backup lokalny ze skillami, projektami i sekretami jest dostępny w sekcji `Backup` aplikacji.

## Kody zakończenia i błędy

Powodzenie kończy proces kodem `0`. Błąd jest wypisywany na standardowe wyjście błędów i kończy proces kodem `1`, dzięki czemu CLI może być używane w skryptach.
