# Agentbox CLI — instrukcja

CLI korzysta z tej samej biblioteki co aplikacja. W wydaniu DMG przejdź do `Ustawienia → Wiersz poleceń (CLI)` i wybierz `Zainstaluj CLI`. Aplikacja utworzy dowiązanie `/usr/local/bin/agentbox` do binarki dołączonej do bundla, dlatego CLI będzie aktualizowane razem z aplikacją.

Po instalacji uruchom pomoc poleceniem:

```bash
agentbox --help
```

Podczas pracy ze źródłami można używać `swift run agentbox --help` albo `.build/release/agentbox`. Zmienna `SKILLBOX_HOME` wskazuje inną bibliotekę:

```bash
SKILLBOX_HOME="$HOME/Documents/AgentboxData" agentbox list
```

## Skille

```bash
agentbox list
agentbox new moje-notatki [--name "Moje notatki"] [--description "Zasady"] [--tags praca] [--file plik|-]
agentbox add ./folder-skilla [--id nazwa]
agentbox add https://github.com/user/repo.git [--path skills] [--branch main] [--id nazwa]
agentbox tag nazwa-skilla seo audit
agentbox update nazwa-skilla
agentbox update --all
agentbox delete nazwa-skilla
```

`new` tworzy skill prosto w bibliotece z podanej treści. `--file` wskazuje plik, a `--file -` czyta standardowe wejście, więc skill można podać potokiem. Bez `--file` powstaje krótki szkic do uzupełnienia. Treść zaczynająca się od bloku `---` jest zapisywana bez zmian; w pozostałych przypadkach Agentbox dopisuje nagłówek YAML z `--name` i `--description`.

`add` kopiuje lokalny skill albo importuje wszystkie znalezione `SKILL.md` z Git. `tag` zastępuje listę tagów wskazanego skilla. `update` działa dla skilli pochodzących z Git. `delete` usuwa skill z biblioteki i jego bezpośrednie przypisania do projektów — tak samo jak `Usuń` w szczegółach skilla; nie rusza katalogu źródłowego ani repozytorium.

`agentbox update --all` najpierw sprawdza zdalne rewizje wszystkich skilli Git, a następnie pobiera wyłącznie dostępne aktualizacje. Skille lokalne są pomijane. Aktualizacja biblioteki nie zmienia automatycznie plików projektów — po niej uruchom `agentbox sync project <nazwa>` dla projektów, które mają otrzymać nowe wersje.

## Projekty

```bash
agentbox project list
agentbox project add sklep /pełna/ścieżka/do/sklepu --tools claude,codex,opencode
agentbox project set sklep --skills seo-audit,docx --tags seo
```

`project set` ustawia bezpośrednie skille i dynamiczne tagi. Pusta opcja usuwa wcześniejsze przypisania danego typu.

```bash
agentbox project status
agentbox project adopt sklep
agentbox project adopt sklep --yes
agentbox project unsync sklep
agentbox project remove sklep
agentbox project remove sklep --clean
```

`project status` pokazuje jednym rzutem, które projekty odstają od biblioteki: `✓` aktualny, `●` z liczbą zmian, `✗` zablokowany przez niezarządzany katalog lub wpis, `?` brak folderu projektu.

`project adopt` wypisuje katalogi ze `SKILL.md`, które leżą w projekcie, nie są zarządzane przez Agentbox i nie mają odpowiednika w bibliotece. Bez `--yes` tylko je wylicza; z `--yes` kopiuje je do biblioteki jako skille lokalne.

`project unsync` usuwa z folderu projektu wyłącznie to, co Agentbox ma w swoich manifestach. Ręcznie dodane skille i serwery MCP zostają nietknięte, a przed zmianą powstaje backup.

`project remove` usuwa wpis projektu i jego przypisania MCP z Agentbox — folder projektu i jego pliki zostają bez zmian. `--clean` najpierw robi to, co `project unsync` (sprząta katalogi skilli i wpisy MCP z manifestów Agentbox), a dopiero potem usuwa projekt.

### Foldery nadrzędne i nowe podfoldery

```bash
agentbox project root-add workspace ~/Projekty --tools claude --skills styl --folders sklep,blog
agentbox project root-adopt workspace ~/Projekty --skills styl [--keep-own blog]
agentbox project roots
agentbox project scan [--root workspace]
agentbox project adopt-new [--root workspace] --yes [--sync]
agentbox project ignore-new [--root workspace]
agentbox project unignore workspace
```

`project root-add` tworzy folder nadrzędny z ustawieniami wspólnymi dla jego podfolderów — tak samo jak `Dodaj wiele` w aplikacji. `--folders` wybiera podfoldery, które od razu stają się projektami; pominięcie tej opcji dodaje sam folder, a jego podfoldery zaproponuje `project scan`. `--no-watch` wyłącza wykrywanie nowych podfolderów, a `--gitignore` włącza dopisywanie plików MCP do `.gitignore` projektów.

`project root-adopt` robi to samo dla folderu, którego projekty są już w Agentbox: wszystkie przechodzą na wspólne ustawienia, a `--keep-own` wymienia te, które mają zachować własne. Bez `--tools` folder dostaje sumę narzędzi swoich projektów.

`project roots` wypisuje foldery nadrzędne dodane w aplikacji przez `Dodaj wiele`: ścieżkę, liczbę projektów, czy folder jest obserwowany i jego narzędzia.

`project scan` pokazuje podfoldery, które pojawiły się w obserwowanych folderach i nie są jeszcze projektami. `project adopt-new` dodaje je jako projekty korzystające z ustawień folderu — bez `--yes` tylko je wylicza, a `--sync` synchronizuje je od razu po dodaniu. `project ignore-new` zapamiętuje odmowę, więc te podfoldery nie wracają w kolejnych skanach, a `project unignore <folder>` czyści tę listę.

Projekt korzystający z ustawień folderu nadrzędnego odrzuca `project set` i `mcp assign` z komunikatem: zmień ustawienia folderu albo nadaj projektowi własne w aplikacji.

## Synchronizacja skilli

```bash
agentbox sync project sklep
agentbox sync project sklep --dry-run
agentbox sync all
agentbox sync global --skills seo-audit,docx --tags seo --tools claude,opencode
agentbox sync global --dry-run
```

`sync project` i `sync all` synchronizują skille i MCP razem, tą samą ścieżką transakcyjną co GUI: przed zapisem powstaje backup projektu, a błąd cofa zmiany. `sync all` zatrzymuje serię na pierwszym błędzie i wypisuje wynik dla każdego projektu — `✓` zsynchronizowany, `✗` cofnięty, `–` pominięty.

`sync global` zapisuje wybór skilli, tagów i narzędzi, a następnie kopiuje je do katalogów użytkownika (`~/.claude/skills`, `~/.codex/skills`, `~/.config/opencode/skills`). Wywołany bez `--skills` i `--tags` używa wyboru zapisanego wcześniej w aplikacji.

`--dry-run` pokazuje planowane zmiany bez zapisu.

Synchronizacja zatrzymuje się, jeśli w katalogu docelowym istnieje katalog skilla o tej samej nazwie, którego Agentbox nie ma w swoim manifeście. Ręcznie napisany skill nie zostanie nadpisany — usuń go lub zmień nazwę, jeśli ma go zastąpić wersja z biblioteki.

## Pełny workflow

```bash
agentbox refresh
agentbox refresh --remote git@github.com:user/agentbox-backup.git --message "Aktualizacja biblioteki"
```

`refresh` wykonuje kolejno: sprawdzenie i pobranie aktualizacji skilli Git, pełny backup lokalny, commit i push backupu Git oraz transakcyjną synchronizację skilli i MCP we wszystkich projektach. Push jest obowiązkowy; jeśli biblioteka nie ma skonfigurowanego `origin`, podaj `--remote`. Błąd zatrzymuje workflow, a synchronizacja aktualnie przetwarzanego projektu korzysta z automatycznego rollbacku. Projekty zakończone wcześniej pozostają zsynchronizowane.

Przebieg kończy blok `PODSUMOWANIE` z bilansem całości:

```text
────────────────────────────────────────────────────
PODSUMOWANIE
  Skille          zaktualizowano 1: docx
  Backup lokalny  2026-08-26T06-24-18.361Z-2EA9FA54
  Backup Git      To github.com:user/repo.git · abc..def  main -> main
  Projekty        4 — ✓ 1 zsynchronizowano, = 1 bez zmian, ✗ 1 cofnięto, – 1 pominięto
  Wymaga uwagi:
    ✗ gamma — niezarządzany katalog .claude/skills/docx
    – delta — nie próbowano po błędzie
```

Sekcja `Wymaga uwagi` pojawia się tylko wtedy, gdy któryś projekt został cofnięty. Kod wyjścia nie zmienia się z tego powodu — `refresh` kończy się zerem, dopóki sam workflow nie rzuci błędem.

## MCP

```bash
agentbox mcp list

agentbox mcp server add context7 \
  --command npx \
  --args=-y,@upstash/context7-mcp \
  --env TOKEN=TOKEN \
  --tags seo,docs

agentbox mcp server add docsearch \
  --url https://mcp.example.com/mcp \
  --headers Authorization=DOCSEARCH_TOKEN \
  --tags seo

agentbox mcp assign sklep --servers context7 --tags seo
agentbox mcp preview sklep
agentbox mcp sync sklep
agentbox mcp server remove docsearch
```

`mcp assign` zastępuje bezpośrednie serwery i tagi MCP projektu. Wartości `--env` i `--headers` są odwołaniami do zmiennych systemowych, nie lokalnymi sekretami. Pełną klasyfikacją sekretów istniejącego MCP zarządza obecnie interfejs aplikacji.

`mcp server remove` usuwa serwer z biblioteki, jego bezpośrednie przypisania do projektów i jego wartości z lokalnego pliku sekretów — tak samo jak `Usuń` przy serwerze w aplikacji.

### Globalne serwery Codex i Claude Code

Codex CLI, jego wtyczka IDE i aplikacja ChatGPT Desktop dzielą jeden plik `~/.codex/config.toml` — serwer MCP dodany w dowolnym z nich ładuje się automatycznie w każdym projekcie. Claude Code ma podobny mechanizm: serwer dodany w zasięgu `user` (`~/.claude.json`) też trafia do każdego projektu. Agentbox nie zarządza tymi plikami — tylko je odczytuje i pozwala wyłączyć wybrany serwer dla jednego projektu, bez ruszania globalnej definicji.

```bash
agentbox mcp global list sklep
agentbox mcp global disable sklep codex apple-mail
agentbox mcp global enable sklep codex apple-mail
agentbox sync project sklep

# folder ze wspólnymi ustawieniami — jedna decyzja dla wszystkich jego projektów
agentbox mcp global list praca --folder
agentbox mcp global disable praca codex apple-mail --folder
agentbox sync all
```

`--folder` adresuje folder nadrzędny zamiast pojedynczego projektu. To jedyny sposób, żeby zmienić wybór dla projektu, który dziedziczy ustawienia z folderu — jego własny wpis nie zawiera niczego, co dałoby się zmienić. Próba użycia takiego projektu wprost kończy się błędem, który podaje nazwę folderu i gotową komendę.

`global disable`/`global enable` tylko zapisują wybór — trzeba potem zsynchronizować projekt, żeby trafił do plików. Dla Codexa Agentbox dopisuje do `.codex/config.toml` samo `enabled = false` (bez powtarzania `command`/`args` — to udokumentowany sposób Codexa na nadpisanie jednego pola z warstwy globalnej). Dla Claude Code nazwa trafia do `disabledMcpServers` w `.claude/settings.local.json`, obok pozostałych, niezwiązanych z Agentboksem ustawień w tym pliku, które zostają nietknięte. Ten plik jest dopisywany do `.git/info/exclude` dopiero wtedy, gdy faktycznie trafi do niego wyłączenie — i pod własnym nagłówkiem, nie razem z plikami MCP, które mogą zawierać sekrety.

## Dokumenty

```bash
agentbox docs list
agentbox docs new standard --tags backend --file agents.md
agentbox docs tag standard backend web
agentbox docs assign sklep --docs standard --tags backend
agentbox docs preview sklep
agentbox docs sync sklep
agentbox docs delete standard
```

`docs assign` zastępuje bezpośrednie dokumenty i tagi projektu — dokładnie jak `mcp assign`. Do jednego projektu może pasować tylko jeden dokument naraz; więcej dopasowań przez tagi jest konfliktem, który `docs preview`/`docs sync` zgłoszą zamiast wybrać dowolny.

Zsynchronizowany dokument ląduje jako `AGENTS.md` (pełna treść) i `CLAUDE.md` (wygenerowany import `@AGENTS.md`) w katalogu głównym projektu, niezależnie od tego, jakie narzędzia ma projekt zaznaczone.

## Odtworzenie biblioteki

```bash
agentbox restore --remote git@github.com:user/agentbox-backup.git
```

Pobiera skille, `catalog.json`, `mcp.json` i `docs.json` z repozytorium backupu — na przykład przy konfiguracji nowego Maca. Projekty, lokalne ścieżki i sekrety tego Maca pozostają bez zmian. Przed zapisem powstaje pełny backup lokalny, a `.git` klona jest przejmowany, więc kolejne `agentbox backup` wypychają do tego samego repozytorium.

Sekrety MCP celowo nie trafiają do tego repozytorium, więc serwery, które ich wymagają, ruszą na nowym Maku dopiero po ich uzupełnieniu. Najszybciej: skopiuj `mcp-secrets.json` z ostatniego pełnego backupu starego Maca (`<biblioteka>/backups/full/<data>/mcp-secrets.json`) do folderu nowej biblioteki przez AirDrop albo inny bezpieczny kanał.

## Backup Git

```bash
agentbox backup
agentbox backup --message "Aktualizacja konfiguracji"
agentbox backup --remote git@github.com:user/agentbox-backup.git
```

Backup Git nie zawiera projektów, lokalnych ścieżek, sekretów ani folderu `backups/`. Pełny backup lokalny ze skillami, projektami i sekretami jest dostępny w sekcji `Backup` aplikacji.

## Kody zakończenia i błędy

Powodzenie kończy proces kodem `0`. Błąd jest wypisywany na standardowe wyjście błędów i kończy proces kodem `1`, dzięki czemu CLI może być używane w skryptach.
