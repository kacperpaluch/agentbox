# Agentbox — instrukcja użytkownika

## Pierwsze uruchomienie

1. Dodaj skill z lokalnego katalogu albo repozytorium Git.
2. Dodaj projekt i wybierz obsługiwane narzędzia.
3. Przypisz skille bezpośrednio lub przez tagi dynamiczne.
4. Opcjonalnie zaimportuj serwery MCP i utwórz preset.
5. W projekcie wybierz `Synchronizuj wszystko`, sprawdź plan zmian i zatwierdź.
6. Skonfiguruj lokalny lub zdalny backup Git biblioteki.

## Klasyfikacja wartości MCP

Podczas analizy JSON Agentbox proponuje typ każdej zmiennej środowiskowej i każdego nagłówka. Przed importem można zmienić propozycję.

- `Zmienna systemowa` — Agentbox zapisuje nazwę zmiennej, a wartość ma dostarczyć środowisko procesu klienta AI.
- `Sekret lokalny` — wartość trafia do lokalnego `mcp-secrets.json`, który jest wyłączony z backupu Git. Plik nie jest obecnie szyfrowany.
- `Zwykła wartość` — wartość trafia do `mcp.json` i może znaleźć się w backupie Git.

Automatyczne rozpoznawanie jest tylko sugestią. Agentbox uznaje za podejrzane nazwy lub wartości zawierające między innymi `token`, `password`, `api_key`, `cookie`, `secret`, `authorization` lub `bearer`. Nietypowo nazwany sekret może zostać błędnie uznany za zwykłą wartość, dlatego klasyfikację należy sprawdzić.

Sekret przechowywany poza backupem biblioteki może zostać zapisany jawnie w wynikowym pliku MCP projektu, jeśli format klienta tego wymaga. Przed synchronizacją Agentbox pokazuje pełną treść wynikowych konfiguracji. Preferuj zmienne systemowe, jeśli klient je obsługuje.

## Podgląd i synchronizacja

Podgląd projektu pokazuje osobno dla Claude, Codex i OpenCode:

- docelowy katalog skilli;
- skille dodawane, ponownie zapisywane i usuwane;
- serwery MCP dodawane i usuwane;
- pełną wynikową treść plików MCP.

Synchronizacja skilli i MCP jest jedną operacją. Przed zapisem Agentbox tworzy backup zarządzanych katalogów i plików w `.skillbox/sync-backups/`. Jeśli którykolwiek etap zakończy się błędem, wcześniejsze zmiany tej operacji są automatycznie wycofywane. Zachowywanych jest 10 ostatnich backupów.

Obce skille i ręczne wpisy MCP nie są przejmowane przez Agentbox. Konflikt nazwy z ręcznym wpisem zatrzymuje operację przed zapisem.

## Historia operacji i błędy

Przycisk z ikoną historii na pasku narzędzi otwiera listę sukcesów i błędów z bieżącej sesji. Komunikat może zniknąć z dolnej części okna, ale pozostaje w historii i można skopiować jego treść.

W przypadku błędu synchronizacji:

1. otwórz historię operacji i skopiuj komunikat;
2. sprawdź, czy folder projektu istnieje i jest zapisywalny;
3. usuń konflikt ręcznego wpisu MCP albo zmień nazwę serwera;
4. ponownie otwórz podgląd — Agentbox nie zapisuje planu, który nie przechodzi walidacji.

## Snapshoty biblioteki i backup Git

Przed zmianą plików danych Agentbox zachowuje rotacyjne snapshoty w:

```text
<biblioteka>/.agentbox-snapshots/
```

Snapshot zawiera bieżące wersje `catalog.json`, `projects.local.json` i `mcp.json`. Zachowywanych jest 10 ostatnich snapshotów. Sekrety nie są do nich kopiowane. Folder snapshotów jest wyłączony z backupu Git.

Backup Git obejmuje `catalog.json`, `mcp.json` i `skills/`. Nie obejmuje lokalnych ścieżek projektów ani sekretów. Git zapewnia długoterminową historię biblioteki, natomiast snapshoty chronią ostatni stan przed przypadkowym lub uszkodzonym zapisem.

Przed ręcznym przywracaniem zamknij Agentbox. Skopiuj potrzebne pliki z jednego, kompletnego katalogu snapshotu do katalogu biblioteki. Jeśli problem dotyczy skilli lub historii konfiguracji, można również przywrócić odpowiedni commit Git.

## Pliki projektu i Git

Agentbox dopisuje generowane konfiguracje MCP oraz `.skillbox/` do lokalnego `.git/info/exclude`. Nie usuwa to pliku, który został wcześniej dodany do indeksu Git. Po pierwszej synchronizacji sprawdź:

```bash
git status
git ls-files .mcp.json .codex/config.toml opencode.json opencode.jsonc
```

Jeżeli któreś z tych poleceń pokaże plik zawierający sekret, usuń go z indeksu i sprawdź historię repozytorium.

