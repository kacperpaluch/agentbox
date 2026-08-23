# Agentbox

Agentbox to natywna aplikacja macOS i CLI do zarządzania skillami oraz serwerami MCP dla Claude Code, Codex i OpenCode. Definicje są przechowywane w jednej bibliotece, a wybrane zestawy synchronizowane do folderów konkretnych projektów.

Projekt jest obecnie MVP. Agentbox nie uruchamia serwerów MCP i nie zastępuje klientów AI — przygotowuje dla nich pliki konfiguracyjne i katalogi skilli.

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

Skrypty wykonują build release, tworzą `dist/Agentbox.app` oraz opcjonalnie `dist/Agentbox-0.1.0.dmg` i podpisują aplikację lokalnym podpisem ad-hoc. W DMG znajduje się także skrót do `Applications`. Taki bundle działa na bieżącym Macu, ale nie jest jeszcze podpisany certyfikatem Apple Developer ani notarized do publicznej dystrybucji, dlatego macOS może przy pierwszym uruchomieniu wymagać użycia `Otwórz` z menu kontekstowego.

## Folder biblioteki

Domyślna lokalizacja to `~/Library/Application Support/Skillbox`. Stara nazwa została zachowana, aby aktualizacja aplikacji nie odcięła danych utworzonych podczas testów MVP. Folder można zmienić w `Ustawienia → Folder biblioteki`; dane zostaną skopiowane do pustego katalogu, a poprzedni pozostanie jako kopia.

```text
Skillbox/
├── catalog.json           # katalog skilli, źródła i tagi
├── projects.local.json    # projekty i lokalne ścieżki
├── mcp.json               # serwery, presety i przypisania MCP
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
```

### Usuwanie

`Usuń` w szczegółach skilla usuwa jego kopię z biblioteki i bezpośrednie przypisania do projektów. Nie modyfikuje źródłowego katalogu ani repozytorium. Wcześniej zsynchronizowana kopia znika z projektu podczas kolejnej synchronizacji.

## Projekty i synchronizacja

Projekt wskazuje istniejący folder na dysku oraz obsługiwane narzędzia. Można mu przypisać pojedyncze skille, tagi dynamiczne, presety MCP i warianty serwerów, np. `n8n: Domyślny` albo `n8n: Tailscale`.

`Synchronizuj wszystko` pokazuje podgląd MCP, a po zatwierdzeniu synchronizuje skille i konfiguracje MCP.

| Narzędzie | Skille w projekcie | MCP w projekcie |
|---|---|---|
| Claude Code | `.claude/skills/` | `.mcp.json` |
| Codex | `.codex/skills/` | `.codex/config.toml` |
| OpenCode | `.opencode/skills/` | istniejący `opencode.jsonc` lub nowy `opencode.json` |

Plik `.skillbox.json` w każdym katalogu skilli śledzi tylko elementy zarządzane przez Agentbox. Obce katalogi nie są usuwane.

Usunięcie projektu usuwa jedynie wpis i przypisania MCP z Agentbox. Folder projektu i wszystkie jego pliki pozostają na dysku.

## MCP

### Serwery, presety i profile

Obsługiwane są lokalne serwery STDIO i zdalne HTTP, argumenty, zmienne środowiskowe, nagłówki, wartości lokalne oraz odwołania do zmiennych systemowych. Serwery można łączyć w presety. Wykryte warianty jednego serwera można wybierać osobno dla każdego projektu.

Usunięcie serwera usuwa go ze wszystkich presetów i kasuje jego wartości z lokalnego pliku sekretów. Usunięcie presetu usuwa jego przypisania do projektów. Wynikowe pliki projektów są aktualizowane podczas kolejnej synchronizacji.

### Import JSON

`Importuj lub użyj AI → Mam JSON` obsługuje cały obiekt z `mcpServers`, samą mapę serwerów oraz plik JSON. Po analizie pokazuje typy, liczbę sekretów i profile. Można zaznaczyć tylko wybrane serwery do importu.

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
swift run agentbox mcp preset add seo --servers context7,senuto
swift run agentbox mcp assign website --presets seo
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

Po pierwszym ręcznym backupie GUI może automatycznie tworzyć lokalne commity po zmianach skilli, tagów, serwerów i presetów MCP. Zmiany wykonane w ciągu 5 sekund są łączone w jeden commit. Automatyczny push do `origin` ma osobny przełącznik i domyślnie jest wyłączony. Projekty, sekrety, klucze AI i sama synchronizacja folderu projektu nie uruchamiają automatycznego backupu.

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
3. Zaimportuj serwery MCP i utwórz presety.
4. Dodaj projekt i wskaż jego folder.
5. Wybierz narzędzia, skille, tagi, presety i profile MCP.
6. Kliknij `Synchronizuj wszystko`.
7. Sprawdź podgląd i zatwierdź zapis.
8. Uruchom wybranego klienta w folderze projektu.
9. Dokończ OAuth w kliencie, jeśli serwer go wymaga.
10. Wykonaj backup biblioteki do Git.
