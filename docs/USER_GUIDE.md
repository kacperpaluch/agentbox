# Agentbox — instrukcja użytkownika

## Pierwsze uruchomienie

1. Dodaj skill z lokalnego katalogu albo repozytorium Git.
2. Dodaj projekt i wybierz obsługiwane narzędzia.
3. Przypisz skille bezpośrednio lub przez tagi dynamiczne.
4. Opcjonalnie zaimportuj serwery MCP i przypisz im tagi.
5. W projekcie wybierz `Synchronizuj wszystko`, sprawdź plan zmian i zatwierdź.
6. Skonfiguruj lokalny lub zdalny backup Git biblioteki.

## Aktualizacje aplikacji

Od wersji 0.3.0 Agentbox używa Sparkle i raz dziennie sprawdza podpisany kanał aktualizacji. W `Ustawienia → Aktualizacje` można osobno włączyć automatyczne sprawdzanie oraz pobieranie, a przycisk `Sprawdź teraz` uruchamia kontrolę ręcznie. To samo polecenie jest dostępne w menu aplikacji.

Numer zainstalowanej wersji i buildu jest stale widoczny na dole paska bocznego. Każde sprawdzenie aktualizacji używa unikalnego parametru URL, dzięki czemu nieaktualna kopia feedu nie jest pobierana z cache.

Każdy obraz aktualizacji jest weryfikowany kluczem EdDSA osadzonym w aplikacji. Prywatny klucz wydawcy pozostaje w macOS Keychain i nie jest przechowywany w repozytorium. Ponieważ wydanie nie ma jeszcze podpisu Developer ID ani notaryzacji Apple, Gatekeeper może wymagać zatwierdzenia aplikacji przez `Otwórz` z menu kontekstowego. Wersję 0.3.0 należy zainstalować ręcznie; mechanizm automatyczny obsłuży następne wydania.

## Klasyfikacja wartości MCP

Podczas analizy JSON Agentbox proponuje typ każdej zmiennej środowiskowej i każdego nagłówka. Przed importem można zmienić propozycję.

- `Zmienna systemowa` — Agentbox zapisuje nazwę zmiennej, a wartość ma dostarczyć środowisko procesu klienta AI.
- `Sekret lokalny` — wartość trafia do lokalnego `mcp-secrets.json`, który jest wyłączony z backupu Git. Plik nie jest obecnie szyfrowany.
- `Zwykła wartość` — wartość trafia do `mcp.json` i może znaleźć się w backupie Git.

Automatyczne rozpoznawanie jest tylko sugestią. Agentbox uznaje za podejrzane nazwy lub wartości zawierające między innymi `token`, `password`, `api_key`, `cookie`, `secret`, `authorization` lub `bearer`. Nietypowo nazwany sekret może zostać błędnie uznany za zwykłą wartość, dlatego klasyfikację należy sprawdzić.

Sekret przechowywany poza backupem biblioteki może zostać zapisany jawnie w wynikowym pliku MCP projektu, jeśli format klienta tego wymaga. Przed synchronizacją Agentbox pokazuje pełną treść wynikowych konfiguracji. Preferuj zmienne systemowe, jeśli klient je obsługuje.

## Podgląd i synchronizacja

### Wybór MCP w projekcie

Serwery MCP wybiera się tak samo jak skille: pojedynczo albo dynamicznie według tagów. Oba sposoby można łączyć, a projekt może korzystać równocześnie z dowolnej liczby serwerów, również takich, które wcześniej były traktowane jako wzajemnie wykluczające się warianty.

Tagi dodaje się w szczegółach serwera MCP. Menu `Używane tagi` pokazuje istniejące wartości, co pomaga zachować jednolite nazwy. To samo menu jest dostępne podczas tagowania pojedynczych i wielu skilli. Stare przypisania presetów są zachowane przy odczycie i zamieniane na bezpośredni wybór serwerów przy następnym zapisie projektu.

### Dodawanie wielu projektów

W sekcji `Projekty` wybierz `Dodaj wiele`, a następnie wskaż folder nadrzędny. Agentbox pokaże jego bezpośrednie, nieukryte podfoldery. Zaznacz projekty i ustaw wspólne narzędzia, pojedyncze skille i MCP oraz dynamiczne tagi obu typów. Podfolder zapisany już jako projekt jest oznaczony i nie można dodać go ponownie.

Ustawienia są kopiowane w chwili importu. Późniejsza edycja jednego projektu nie zmienia pozostałych; folder nadrzędny nie jest trwałym szablonem ani źródłem dziedziczenia.

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

## Odzyskiwanie

Przed zmianą plików danych Agentbox zachowuje rotacyjne snapshoty w:

```text
<biblioteka>/.agentbox-snapshots/
```

Snapshot zawiera bieżące wersje `catalog.json`, `projects.local.json` i `mcp.json`. Zachowywanych jest 10 ostatnich snapshotów. Sekrety nie są do nich kopiowane. Folder snapshotów jest wyłączony z backupu Git.

W sekcji `Odzyskiwanie → Snapshoty biblioteki` można wybrać kopię na podstawie daty i przywrócić zapisane w niej pliki. Katalog `skills/` i `mcp-secrets.json` nie są zmieniane. Przed przywróceniem Agentbox tworzy snapshot aktualnego stanu.

Sekcja `Odzyskiwanie → Backupy synchronizacji projektów` pokazuje zarządzane ścieżki zapisane przed synchronizacją. Przywrócenie cofa katalogi skilli, pliki MCP i manifest do wybranego stanu. Najpierw tworzony jest nowy backup aktualnego projektu, dzięki czemu można cofnąć również operację odzyskiwania.

Backupy utworzone przez wersję 0.2.0 przed dodaniem metadanych pozostają na dysku, ale nie pojawiają się w GUI, ponieważ nie da się bezpiecznie przypisać plików `item-*` do oryginalnych ścieżek.

Backup Git obejmuje `catalog.json`, `mcp.json` i `skills/`. Nie obejmuje lokalnych ścieżek projektów ani sekretów. Git zapewnia długoterminową historię biblioteki, natomiast snapshoty chronią ostatni stan przed przypadkowym lub uszkodzonym zapisem.

Jeśli problem dotyczy katalogu skilli lub długoterminowej historii konfiguracji, można również przywrócić odpowiedni commit Git. Ta operacja nie jest jeszcze dostępna w GUI.

## Pliki projektu i Git

Agentbox dopisuje generowane konfiguracje MCP oraz `.skillbox/` do lokalnego `.git/info/exclude`. Nie usuwa to pliku, który został wcześniej dodany do indeksu Git. Po pierwszej synchronizacji sprawdź:

```bash
git status
git ls-files .mcp.json .codex/config.toml opencode.json opencode.jsonc
```

Jeżeli któreś z tych poleceń pokaże plik zawierający sekret, usuń go z indeksu i sprawdź historię repozytorium.
