# Agentbox

Agentbox to natywna aplikacja macOS i CLI do zarządzania skillami oraz serwerami MCP dla Claude Code, Codex i OpenCode. Definicje są przechowywane w jednej bibliotece, a wybrane zestawy synchronizowane do folderów konkretnych projektów.

Projekt jest obecnie MVP. Agentbox nie uruchamia serwerów MCP i nie zastępuje klientów AI — przygotowuje dla nich pliki konfiguracyjne i katalogi skilli.

Szczegółowy opis pierwszego uruchomienia, klasyfikacji sekretów, bezpiecznej synchronizacji i odzyskiwania danych znajduje się w [instrukcji użytkownika](docs/USER_GUIDE.md). Wszystkie polecenia terminalowe opisuje [instrukcja CLI](docs/CLI.md). Historia wydań i zmian jest prowadzona w [changelogu](CHANGELOG.md).

## Wymagania i uruchomienie

- macOS 14 lub nowszy,
- Xcode i Swift 6,
- Git do importowania i aktualizowania skilli,
- opcjonalnie klucz OpenAI lub Anthropic dla asystenta MCP.

```bash
swift run AgentboxApp       # interfejs macOS
swift run agentbox --help   # CLI
swift test                  # testy
```

Gotowy bundle aplikacji można zbudować poleceniem:

```bash
./scripts/build-app.sh
open dist/Agentbox.app

# aplikacja w obrazie instalacyjnym DMG
./scripts/build-dmg.sh
```

Publikację gotowego DMG można wykonać przez `./scripts/publish-release.sh <wersja> <plik-notatek>`. Skrypt tworzy GitHub Release, potwierdza upload artefaktu i dopiero wtedy usuwa lokalne `Agentbox.app` oraz `Agentbox-*.dmg` z `dist/`.

Skrypty wykonują build release GUI i CLI, umieszczają oba pliki wykonywalne w `dist/Agentbox.app`, tworzą wersjonowany obraz `dist/Agentbox-<wersja>.dmg` i podpisują aplikację lokalnym podpisem ad-hoc. W DMG znajduje się także skrót do `Applications`. Po przeniesieniu aplikacji do `Aplikacje` polecenie terminalowe można włączyć przez `Ustawienia → Wiersz poleceń (CLI) → Zainstaluj CLI`. Symlink wskazuje binarkę wewnątrz aplikacji, więc aktualizacje Agentbox obejmują też CLI. Taki bundle działa na bieżącym Macu, ale nie jest jeszcze podpisany certyfikatem Apple Developer ani notarized do publicznej dystrybucji, dlatego macOS może przy pierwszym uruchomieniu wymagać użycia `Otwórz` z menu kontekstowego.

Od wersji 0.3.0 Agentbox sprawdza raz dziennie podpisany kanał aktualizacji Sparkle. Zachowanie można zmienić w `Ustawienia → Aktualizacje`, a ręczne sprawdzenie uruchomić z menu aplikacji. Wersję 0.3.0 trzeba jeszcze zainstalować ręcznie; kolejne wydania będą już dostępne z poziomu aplikacji. Brak Developer ID oznacza, że przy pierwszym uruchomieniu nowo zainstalowanej wersji macOS może nadal wyświetlić ostrzeżenie Gatekeepera.

## Folder biblioteki

Domyślna lokalizacja to `~/Library/Application Support/Skillbox`. Stara nazwa została zachowana, aby aktualizacja aplikacji nie odcięła danych utworzonych podczas testów MVP. W `Ustawienia → Folder biblioteki` można podłączyć istniejącą bibliotekę bez kopiowania albo wskazać pusty katalog, do którego zostaną skopiowane aktualne dane.

```text
Skillbox/
├── catalog.json           # katalog skilli, źródła i tagi
├── projects.local.json    # projekty i lokalne ścieżki
├── mcp.json               # serwery, tagi i przypisania MCP
├── mcp-secrets.json       # sekrety i klucze AI, bez szyfrowania
└── skills/
    └── nazwa-skilla/SKILL.md
```

Dla CLI można wskazać inną bibliotekę:

```bash
SKILLBOX_HOME="$HOME/Documents/AgentboxData" swift run agentbox list
```

## Skille

### Dodawanie

`Z dysku` przyjmuje katalog zawierający `SKILL.md` i kopiuje cały skill do biblioteki. `Z Git` przyjmuje URL oraz opcjonalny podfolder. Jeśli znalezionych zostanie wiele katalogów z `SKILL.md`, każdy jest importowany osobno. Można też wkleić kilka URL-i — po jednym w linii.

Linki GitHub wskazujące konkretny katalog są rozpoznawane automatycznie. Przykład `https://github.com/anthropics/skills/tree/main/skills/docx` zostanie rozłożony na repozytorium `anthropics/skills`, branch `main` i podfolder `skills/docx`.

```bash
swift run agentbox add ./my-skill
swift run agentbox add https://github.com/user/repo.git --path skills
swift run agentbox add https://github.com/user/repo.git --path skills/seo --branch main
```

### Tagi, filtrowanie i aktualizacje

- tagi można edytować w szczegółach skilla,
- checkboxy pozwalają masowo dodawać tagi,
- lista obsługuje wyszukiwanie, filtrowanie po tagu i sortowanie,
- projekt może wskazywać konkretne skille albo dynamiczne tagi,
- `Sprawdź` wykrywa nowe rewizje Git bez automatycznej aktualizacji,
- `Aktualizuj` pobiera nową wersję tylko wskazanego skilla.

```bash
swift run agentbox tag my-skill seo audit
swift run agentbox update my-skill
swift run agentbox update --all
```

`update --all` sprawdza i pobiera wszystkie dostępne aktualizacje skilli Git. Nie synchronizuje automatycznie folderów projektów; po aktualizacji użyj `agentbox sync project <nazwa>` albo `Synchronizuj wszystko` w GUI.

Pełny workflow można wykonać jedną komendą: `agentbox refresh`. Aktualizuje ona skille, tworzy pełny backup lokalny, wykonuje commit i obowiązkowy push backupu Git, a następnie transakcyjnie synchronizuje wszystkie projekty. Jeśli biblioteka nie ma `origin`, trzeba podać `--remote`.

### Usuwanie

`Usuń` w szczegółach skilla usuwa jego kopię z biblioteki i bezpośrednie przypisania do projektów. Nie modyfikuje źródłowego katalogu ani repozytorium. Wcześniej zsynchronizowana kopia znika z projektu podczas kolejnej synchronizacji.

## Projekty i synchronizacja

Projekt wskazuje istniejący folder na dysku oraz obsługiwane narzędzia. Można mu przypisać pojedyncze skille i serwery MCP albo wybierać oba typy dynamicznie według tagów.

Opcja `Dodaj wiele` przyjmuje folder nadrzędny, wykrywa jego bezpośrednie podfoldery i pozwala utworzyć z nich projekty z jednym wspólnym zestawem ustawień. Foldery już dodane do Agentbox są pomijane. Po imporcie każdy projekt ma niezależną kopię konfiguracji i może być edytowany osobno.

Lista projektów jest grupowana według bezpośredniego folderu nadrzędnego, dzięki czemu projekty z jednego katalogu roboczego są widoczne razem.

`Synchronizuj wszystko` przy projekcie pokazuje podgląd i synchronizuje jego skille oraz konfiguracje MCP. `Synchronizuj wszystkie projekty` najpierw przygotowuje plan dla całej listy, a następnie wykonuje tę samą transakcyjną operację kolejno dla każdego projektu.

| Narzędzie | Skille w projekcie | MCP w projekcie |
|---|---|---|
| Claude Code | `.claude/skills/` | `.mcp.json` |
| Codex | `.codex/skills/` | `.codex/config.toml` |
| OpenCode | `.opencode/skills/` | istniejący `opencode.jsonc` lub nowy `opencode.json` |

Plik `.skillbox.json` w każdym katalogu skilli śledzi tylko elementy zarządzane przez Agentbox. Obce katalogi nie są usuwane.

Usunięcie projektu usuwa jedynie wpis i przypisania MCP z Agentbox. Folder projektu i wszystkie jego pliki pozostają na dysku.

## MCP

### Serwery i tagi

Obsługiwane są lokalne serwery STDIO i zdalne HTTP, argumenty, zmienne środowiskowe, nagłówki, wartości lokalne oraz odwołania do zmiennych systemowych. Każdy serwer może mieć tagi. Projekt wybiera dowolne pojedyncze serwery albo wszystkie serwery oznaczone wskazanym tagiem; serwery `n8n` i `n8n-tailscale` mogą działać równocześnie.

Usunięcie serwera usuwa jego bezpośrednie przypisania i kasuje jego wartości z lokalnego pliku sekretów. Wynikowe pliki projektów są aktualizowane podczas kolejnej synchronizacji.

### Import JSON

`Importuj lub użyj AI → Mam JSON` obsługuje cały obiekt z `mcpServers`, samą mapę serwerów oraz plik JSON. Po analizie pokazuje typy i liczbę sekretów. Można zaznaczyć tylko wybrane serwery do importu, a po imporcie przypisać im tagi.

Agentbox proponuje również klasyfikację każdej zmiennej i każdego nagłówka jako `Zmienna systemowa`, `Sekret lokalny` albo `Zwykła wartość`. Przed importem użytkownik może poprawić każdą propozycję. Automatyczne rozpoznawanie jest heurystyką i nie zastępuje sprawdzenia wartości.

### Konfiguracja z AI

W trybie `Mam instrukcję — przygotuj z AI` można wkleić README, instrukcję z GitHuba albo opis. Agentbox korzysta z OpenAI Responses API lub Anthropic Messages API. Wygenerowany JSON jest zawsze pokazywany i wymaga wyboru oraz zatwierdzenia; istniejące sekrety MCP nie są wysyłane do modelu.

OpenAI i Anthropic mają niezależne sekcje w `Ustawienia → Asystent AI do konfiguracji MCP`, każda z własnym modelem i kluczem. Zapisany klucz jest sygnalizowany maską `••••••••`; jego wartość nie jest ponownie wczytywana do formularza. Puste pole zachowuje poprzedni klucz danego dostawcy.

### Bezpieczne scalanie

Agentbox zachowuje niezależne, ręczne ustawienia w plikach projektu. Konflikt nazwy z ręcznym wpisem zatrzymuje synchronizację zamiast nadpisywać dane.

```text
.skillbox/mcp-manifest.json     # wpisy zarządzane przez Agentbox
.skillbox/mcp-backups/<UUID>/   # kopie plików sprzed synchronizacji
```

Agentbox zachowuje maksymalnie 10 ostatnich katalogów kopii MCP. Jeśli źródłem jest `opencode.jsonc`, podgląd ostrzega, że komentarze i formatowanie zostaną utracone podczas przepisania pliku.

GUI pokazuje również pełny plan zmian skilli dla każdego narzędzia. Synchronizacja skilli i MCP działa jako jedna transakcja: błąd na dowolnym etapie przywraca zarządzane katalogi i pliki do stanu sprzed operacji. Ostatnie kopie znajdują się w `.skillbox/sync-backups/`.

Sekcja `Odzyskiwanie` pozwala przywrócić snapshot metadanych biblioteki albo cofnąć zarządzane pliki projektu do stanu sprzed wybranej synchronizacji. Przed przywróceniem Agentbox automatycznie zachowuje aktualny stan.

### Sekrety

Sekrety z importu i klucze AI są zapisywane lokalnie w `mcp-secrets.json`. W MVP plik nie jest szyfrowany i nie trafia do backupu Git. Podczas synchronizacji wartości mogą zostać zapisane jawnie w plikach projektu.

Jeśli projekt jest repozytorium Git, Agentbox dopisuje do lokalnego `.git/info/exclude`:

```text
.mcp.json
.codex/config.toml
opencode.json
opencode.jsonc
```

Nie usuwa to pliku, który został już wcześniej dodany do Git. Zawsze warto sprawdzić `git status` oraz historię repozytorium.

### OAuth

Serwery takie jak Senuto zapisuje się tylko jako URL. Logowanie przez przeglądarkę wykonuje Claude, Codex albo OpenCode. Token OAuth znajduje się w magazynie danego klienta, nie w Agentbox, i nie jest nadpisywany podczas synchronizacji. Każde narzędzie uwierzytelnia się osobno.

### CLI MCP

```bash
swift run agentbox mcp server add context7 --command npx --args "-y,@upstash/context7-mcp"
swift run agentbox mcp server add senuto --url https://mcp.senuto.com/mcp
swift run agentbox mcp assign website --servers context7,senuto --tags seo
swift run agentbox mcp preview website
swift run agentbox mcp sync website
```

CLI rozdziela synchronizację skilli (`agentbox sync project`) i MCP (`agentbox mcp sync`). GUI łączy je w `Synchronizuj wszystko`.

## Backup Git

Backup zawiera `catalog.json`, `skills/` i `mcp.json`. Nie zawiera `projects.local.json` z lokalnymi ścieżkami ani `mcp-secrets.json` z sekretami.

```bash
swift run agentbox backup
swift run agentbox backup --remote git@github.com:user/agentbox-backup.git
swift run agentbox backup --message "Aktualizacja skilli i MCP"
```

Pierwsze wywołanie inicjalizuje Git w folderze biblioteki. `--remote` ustawia `origin`, wykonuje commit zmian i próbuje je wypchnąć.

Po pierwszym ręcznym backupie GUI może automatycznie tworzyć lokalne commity po zmianach skilli, tagów i serwerów MCP. Zmiany wykonane w ciągu 5 sekund są łączone w jeden commit. Automatyczny push do `origin` ma osobny przełącznik i domyślnie jest wyłączony. Projekty, sekrety, klucze AI i sama synchronizacja folderu projektu nie uruchamiają automatycznego backupu.

Przed zapisem danych Agentbox tworzy także lokalny snapshot `catalog.json`, `projects.local.json` i `mcp.json` w `.agentbox-snapshots/`. Zachowuje 10 ostatnich snapshotów; sekrety nie są kopiowane, a folder snapshotów nie trafia do Git.

## Pełny backup lokalny

W `Backup → Pełny backup lokalny` można utworzyć, przywrócić lub usunąć kompletną kopię biblioteki. Czytelny folder powstaje w `backups/full/` i zawiera skille, źródła Git, projekty, lokalne ścieżki, MCP oraz `mcp-secrets.json`. `backups/` jest wyłączony z Git. Kopia zawiera jawne sekrety i nie jest szyfrowana, dlatego należy chronić ją jak plik z hasłami.

## Ograniczenia i bezpieczeństwo MVP

- `mcp-secrets.json` nie jest szyfrowany.
- Podgląd oraz wynikowe pliki MCP mogą zawierać jawne sekrety.
- Agentbox nie uruchamia ani nie testuje serwerów MCP.
- Agentbox nie przeprowadza OAuth i nie zarządza sesją klienta.
- Usunięcie projektu nigdy nie usuwa folderu projektu.
- Aktualizacje Git są wykonywane wyłącznie na żądanie.
- Konfigurację wygenerowaną przez AI należy sprawdzić przed importem.

## Typowy przepływ

1. Dodaj skille z dysku lub Git.
2. Przypisz im tagi.
3. Zaimportuj serwery MCP i przypisz im tagi.
4. Dodaj projekt i wskaż jego folder.
5. Wybierz narzędzia, skille oraz serwery MCP pojedynczo lub według tagów.
6. Kliknij `Synchronizuj wszystko`.
7. Sprawdź podgląd i zatwierdź zapis.
8. Uruchom wybranego klienta w folderze projektu.
9. Dokończ OAuth w kliencie, jeśli serwer go wymaga.
10. Wykonaj backup biblioteki do Git.
