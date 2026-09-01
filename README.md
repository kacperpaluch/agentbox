# Agentbox

Agentbox to natywna aplikacja macOS i CLI do zarządzania skillami oraz serwerami MCP dla Claude Code, Codex i OpenCode. Definicje są przechowywane w jednej bibliotece, a wybrane zestawy synchronizowane do folderów konkretnych projektów.

Agentbox nie uruchamia serwerów MCP i nie zastępuje klientów AI — przygotowuje dla nich pliki konfiguracyjne i katalogi skilli.

W zakładce skilli można zaznaczyć cały nagłówek grupy (repozytorium, tag lub źródło), a następnie zbiorczo dodać tagi albo usunąć zaznaczone skille. Usunięcie zawsze wymaga potwierdzenia i odłącza skille od projektów; katalogi projektów zmienią się dopiero przy kolejnej synchronizacji.

`Projekty → … → Pluginy Claude…` przekazuje instalację marketplace’ów i pluginów do CLI Claude Code dla wskazanego projektu. Wybierz zakres `Projekt`, aby współdzielić wpis w `.claude/settings.json`, albo `Tylko ten Mac` dla `.claude/settings.local.json`. Przed instalacją Agentbox ostrzega, że plugin może zawierać hooki, MCP i programy wykonywalne.

Pluginy można też definiować raz w `Biblioteka → Pluginy`, wybrać dla projektów i instalować podczas zwykłej synchronizacji projektu. Definicje da się poprawiać i usuwać, a projekt z zaznaczonym, jeszcze niezainstalowanym pluginem jest oznaczony jako wymagający synchronizacji.

Szczegółowy opis pierwszego uruchomienia, klasyfikacji sekretów, bezpiecznej synchronizacji i odzyskiwania danych znajduje się w [instrukcji użytkownika](docs/USER_GUIDE.md). Wszystkie polecenia terminalowe opisuje [instrukcja CLI](docs/CLI.md). Historia wydań i zmian jest prowadzona w [changelogu](CHANGELOG.md).

## Jak to wygląda

Pasek boczny ma trzy pozycje: rzeczy, które zbierasz (`Biblioteka`), miejsca, w które trafiają (`Projekty`) oraz `Ustawienia`. Backup i odzyskiwanie są w `Ustawienia → Backup i odzyskiwanie`.

Interfejs jest aktywnie rozwijany, dlatego dokumentacja opisuje przepływy i funkcje zamiast utrwalać wygląd zrzutami ekranu.

## Wymagania i uruchomienie

- macOS 14 lub nowszy,
- Xcode i Swift 6,
- Git do importowania i aktualizowania skilli.

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

Domyślna lokalizacja to `~/Library/Application Support/Skillbox`. Stara nazwa została zachowana, aby aktualizacja aplikacji nie odcięła wcześniej utworzonych danych. W `Ustawienia → Folder biblioteki` można podłączyć istniejącą bibliotekę bez kopiowania albo wskazać pusty katalog, do którego zostaną skopiowane aktualne dane.

```text
Skillbox/
├── catalog.json           # katalog skilli, źródła i tagi
├── selections.json        # co jest przypięte do którego miejsca
├── projects.local.json    # projekty i lokalne ścieżki
├── mcp.json               # definicje serwerów MCP
├── docs.json              # definicje dokumentów
└── skills/
    └── nazwa-skilla/SKILL.md
```

`selections.json` odpowiada na jedno pytanie: co trafia w które miejsce. Jeden klucz na miejsce — id projektu, id folderu nadrzędnego albo `global` — a pod nim narzędzia, skille, tagi skilli, wykluczenia, serwery MCP, tagi MCP, dokument i tagi dokumentów. Pozostałe pliki trzymają już wyłącznie definicje: `catalog.json` skille, `mcp.json` serwery, `docs.json` dokumenty.

Wszystkie wartości MCP — także hasła i tokeny — są przechowywane jawnie, lokalnie w `mcp.json`. Chroń folder biblioteki jak plik z hasłami.

Dla CLI można wskazać inną bibliotekę:

```bash
SKILLBOX_HOME="$HOME/Documents/AgentboxData" swift run agentbox list
```

## Skille

### Dodawanie

`Napisz własny` otwiera edytor, w którym można napisać albo wkleić skill bez zakładania katalogu na dysku — Agentbox dopisuje nagłówek YAML z nazwą i opisem, a wklejony plik z własnym blokiem `---` zapisuje bez zmian. Taki skill jest lokalny, więc później można go edytować w aplikacji. `Z dysku` przyjmuje katalog zawierający `SKILL.md` i kopiuje cały skill do biblioteki. `Z Git` przyjmuje URL oraz opcjonalny podfolder. Jeśli znalezionych zostanie wiele katalogów z `SKILL.md`, każdy jest importowany osobno. Można też wkleić kilka URL-i — po jednym w linii.

Linki GitHub wskazujące konkretny katalog są rozpoznawane automatycznie. Przykład `https://github.com/anthropics/skills/tree/main/skills/docx` zostanie rozłożony na repozytorium `anthropics/skills`, branch `main` i podfolder `skills/docx`.

```bash
swift run agentbox new moje-notatki --name "Moje notatki" --description "Zasady pisania" --file ./notatki.md
swift run agentbox add ./my-skill
swift run agentbox add https://github.com/user/repo.git --path skills
swift run agentbox add https://github.com/user/repo.git --path skills/seo --branch main
```

### Edycja i przejmowanie

Skille dodane z dysku można edytować w aplikacji przyciskiem `Edytuj SKILL.md`; zapis oznacza projekty z tym skillem jako nieaktualne. Skille z Git są tylko do odczytu, bo `Aktualizuj` zastąpiłoby zmiany zawartością repozytorium.

Ręcznie napisany katalog ze `SKILL.md`, który leży w projekcie i blokuje synchronizację, można przejąć do biblioteki przez `⋯ → Przejmij skille z projektu…` albo `agentbox project adopt <nazwa> --yes`. Po przejęciu katalog w projekcie jest identyczny z kopią biblioteczną, więc pierwsza synchronizacja przejmuje go pod zarząd Agentbox — przejęty skill można od razu przypisać i synchronizować także w projekcie, z którego pochodzi.

### Tagi, filtrowanie i aktualizacje

- tagi można edytować w szczegółach skilla,
- checkboxy pozwalają masowo dodawać tagi,
- lista obsługuje wyszukiwanie, filtrowanie po tagu i sortowanie,
- projekt może wskazywać konkretne skille albo dynamiczne tagi,
- `Sprawdź` wykrywa nowe rewizje Git bez automatycznej aktualizacji,
- `Aktualizuj` pobiera nową wersję tylko wskazanego skilla,
- po sprawdzeniu GUI pokazuje też przycisk `Aktualizuj <liczba>`, który pobiera wszystkie wykryte aktualizacje. Nie synchronizuje on automatycznie projektów.

```bash
swift run agentbox tag my-skill seo audit
swift run agentbox update my-skill
swift run agentbox update --all
```

`update --all` sprawdza i pobiera wszystkie dostępne aktualizacje skilli Git. Nie synchronizuje automatycznie folderów projektów; po aktualizacji użyj `agentbox sync project <nazwa>` albo `Synchronizuj wszystko` w GUI.

W GUI `Narzędzia → Odśwież bibliotekę i zsynchronizuj projekty` odpowiada poleceniu `agentbox refresh`: aktualizuje skille, tworzy pełny backup lokalny, a następnie synchronizuje wszystkie projekty.

Pełny workflow można wykonać jedną komendą: `agentbox refresh`. Aktualizuje ona skille, tworzy pełny backup lokalny i transakcyjnie synchronizuje wszystkie projekty.

### Usuwanie

`Usuń` w szczegółach skilla usuwa jego kopię z biblioteki i bezpośrednie przypisania do projektów. Nie modyfikuje źródłowego katalogu ani repozytorium. Wcześniej zsynchronizowana kopia znika z projektu podczas kolejnej synchronizacji.

## Projekty i synchronizacja

Projekt wskazuje istniejący folder na dysku oraz obsługiwane narzędzia. Można mu przypisać pojedyncze skille, serwery MCP i dokument `AGENTS.md`/`CLAUDE.md` albo wybierać każdy typ dynamicznie według tagów.

Opcja `Dodaj wiele` przyjmuje folder nadrzędny, wykrywa jego bezpośrednie podfoldery i pozwala utworzyć z nich projekty. Foldery już dodane do Agentbox są pomijane. Ustawienia zapisują się domyślnie na samym folderze nadrzędnym, a jego projekty je dziedziczą — jedna zmiana w folderze obejmuje wszystkie. Pojedynczy projekt może przejść na własne ustawienia w swoim edytorze, a odznaczenie opcji przy dodawaniu daje każdemu projektowi niezależną kopię konfiguracji.

Projekty dodane wcześniej można objąć wspólnymi ustawieniami przyciskiem `Wspólne ustawienia…` w nagłówku ich grupy.

Folder nadrzędny może też obserwować nowe podfoldery. Świeżo sklonowane repozytorium pojawia się wtedy jako pytanie nad listą projektów: dodać i zsynchronizować, dodać bez synchronizacji, czy pomijać. Odmowa jest zapamiętywana.

Lista projektów jest grupowana według folderu nadrzędnego, dzięki czemu projekty z jednego katalogu roboczego są widoczne razem. Każdą grupę można zwinąć osobno albo rozwinąć i zwinąć wszystkie grupy z menu pod listą.

`Synchronizuj wszystko` przy projekcie pokazuje podgląd i synchronizuje jego skille, konfiguracje MCP oraz dokument. `Synchronizuj wszystkie projekty` najpierw przygotowuje plan dla całej listy, a następnie wykonuje tę samą transakcyjną operację kolejno dla każdego projektu.

| Narzędzie | Skille w projekcie | MCP w projekcie |
|---|---|---|
| Claude Code | `.claude/skills/` | `.mcp.json` |
| Codex | `.codex/skills/` | `.codex/config.toml` |
| OpenCode | `.opencode/skills/` | istniejący `opencode.jsonc` lub nowy `opencode.json` |

Dokument, jeśli jest przypisany, ląduje niezależnie od listy narzędzi jako `AGENTS.md` i `CLAUDE.md` w katalogu głównym projektu — zobacz [Dokumenty](#dokumenty-agentsmd--claudemd).

Plik `.skillbox.json` w każdym katalogu skilli śledzi tylko elementy zarządzane przez Agentbox. Obce katalogi nie są usuwane.

Usunięcie projektu usuwa jedynie wpis i przypisania MCP z Agentbox. Folder projektu i wszystkie jego pliki pozostają na dysku.

## MCP

### Serwery i tagi

Obsługiwane są lokalne serwery STDIO i zdalne HTTP, argumenty, zmienne środowiskowe, nagłówki, wartości lokalne oraz odwołania do zmiennych systemowych. Każdy serwer może mieć tagi. Projekt wybiera dowolne pojedyncze serwery albo wszystkie serwery oznaczone wskazanym tagiem; serwery `n8n` i `n8n-tailscale` mogą działać równocześnie.

Usunięcie serwera usuwa jego bezpośrednie przypisania i kasuje jego wartości z lokalnego pliku sekretów. Wynikowe pliki projektów są aktualizowane podczas kolejnej synchronizacji.

Checkboxy przy serwerach pozwalają zaznaczyć kilka naraz i dodać im tagi jedną operacją — `Dodaj tagi (N)` w pasku akcji, tak samo jak w Bibliotece.

Menu serwera zawiera też `Duplikuj…`. Wpisz własną nową nazwę techniczną, a Agentbox utworzy niezależną kopię 1:1 całej konfiguracji — także URL-a, argumentów, zmiennych, nagłówków, wartości lokalnych i tagów. Kopia nie przejmuje przypisań do projektów — wybierasz ją świadomie tam, gdzie ma działać.

### Import JSON

`Dodaj serwer → JSON` obsługuje cały obiekt z `mcpServers`, samą mapę serwerów, a także pojedynczą definicję serwera (`command`/`args`/`env` albo `url`). Przy pojedynczym obiekcie Agentbox proponuje nazwę z argumentów; można ją wpisać samodzielnie przed analizą. Można zaznaczyć tylko wybrane serwery do importu, a po imporcie przypisać im tagi. Jeśli macOS zamieni cudzysłowy JSON-a na typograficzne, importer rozpozna je automatycznie.

Zakładka `Dodaj serwer → AI` przyjmuje instrukcję instalacji lub fragment README i prosi OpenAI o sam JSON MCP. Klucz API jest używany tylko dla bieżącego żądania — nie zapisuje się w bibliotece. AI nie importuje ani nie synchronizuje niczego samodzielnie: wygenerowany JSON zawsze przechodzi przez podgląd i wybór serwerów.

Wartość zapisana jako `${NAZWA_ZMIENNEJ}` odwołuje się do zmiennej systemowej; każda pozostała wartość jest zapisywana wprost lokalnie w `mcp.json`.

### Edycja jako JSON

`Biblioteka → MCP → Szczegóły → JSON` pokazuje `command`/`args`/`url`/`env`/`headers` jednego serwera jako zwykły tekst do ręcznej edycji. Wartości pozostają lokalne; `${NAZWA_ZMIENNEJ}` oznacza odczyt ze środowiska systemowego. Ten tryb zastępuje sekcję `Zmienne i nagłówki`, zamiast pokazywać ją obok.

Przycisk `Edytuj całą konfigurację` na liście serwerów otwiera osobny, prosty widok dla całej konfiguracji naraz, wypełniony aktualnym stanem: popraw i `Zapisz` — bez kroku analizy i zaznaczania serwerów, bo to edycja własnej konfiguracji, a nie import z zewnątrz. Poprawki nadpisują serwery o tej samej nazwie, reszta zostaje bez zmian. Ta ceremonia (analiza, wybór serwerów, klasyfikacja pól) zostaje tam, gdzie faktycznie jest potrzebna — w `Dodaj serwer → JSON` lub `AI`.

### Bezpieczne scalanie

Agentbox zachowuje niezależne, ręczne ustawienia w plikach projektu. Konflikt nazwy z ręcznym wpisem zatrzymuje synchronizację zamiast nadpisywać dane.

```text
.skillbox/mcp-manifest.json     # wpisy zarządzane przez Agentbox
                                # kopie sprzed zapisu są tymczasowe;
                                # repozytorium dostaje tylko manifest
```

Kopia sprzed zapisu powstaje w katalogu tymczasowym i znika po zakończeniu operacji. Agentbox nie zostawia historii kopii w folderach projektów — repozytorium dostaje wyłącznie manifesty własności. Jeśli źródłem jest `opencode.jsonc`, podgląd ostrzega, że komentarze i formatowanie zostaną utracone podczas przepisania pliku.

GUI pokazuje również pełny plan zmian skilli dla każdego narzędzia. Synchronizacja skilli i MCP działa jako jedna transakcja: błąd na dowolnym etapie przywraca zarządzane katalogi i pliki do stanu sprzed operacji. Kopia użyta do cofnięcia jest tymczasowa i znika po operacji. Projekt bez faktycznych zmian jest pomijany: nic nie jest zapisywane. To samo dotyczy CLI — `agentbox sync project` i `agentbox sync all` używają tej samej ścieżki transakcyjnej.

`Sprawdź stan` sprawdza wszystkie projekty naraz i oznacza każdy z nich: aktualny, liczba zmian do synchronizacji, zablokowany albo brak folderu. To samo w terminalu daje `agentbox project status`.

Agentbox zastępuje wyłącznie katalogi skilli wymienione w swoim manifeście `.skillbox.json`. Katalog o tej samej nazwie, który nie pochodzi z Agentbox, zatrzymuje synchronizację zamiast zostać nadpisany — tak samo jak ręcznie dodany serwer MCP. Jedyny wyjątek to katalog identyczny bajt w bajt z kopią biblioteczną, czyli skill świeżo przejęty z projektu: nadpisanie identycznej zawartości niczego nie niszczy, więc synchronizacja przejmuje go zamiast się zatrzymać.

Pliki konfiguracyjne i manifesty powstają tylko wtedy, gdy projekt ma co synchronizować. Projekt bez wybranych skilli i serwerów MCP pozostaje nietknięty, a puste szkielety (`.mcp.json` z pustym `mcpServers`, `config.toml` z samymi znacznikami) pozostawione przez starsze wersje znikają przy najbliższej synchronizacji. Odznaczenie narzędzia w projekcie również sprząta jego pliki przy kolejnej synchronizacji, zamiast zostawiać je osierocone.

`Synchronizuj wszystkie projekty` liczy plan dla wszystkich projektów przed pierwszym zapisem, a po zakończeniu pokazuje wynik dla każdego projektu osobno: zsynchronizowany, cofnięty po błędzie albo pominięty.

### Skille globalne

`Projekty → Więcej → Skille we wszystkich sesjach…` synchronizuje wybrane skille do katalogów użytkownika zamiast do projektu: `~/.claude/skills`, `~/.codex/skills` i `~/.config/opencode/skills`. Wybór narzędzi, skilli i tagów jest zapisywany, a podgląd pokazuje zmiany przed zapisem. Globalnie trafiają wyłącznie skille — pliki, w których żyłby globalny serwer MCP, to pliki, których Agentbox celowo nigdy nie zapisuje.

### Domyślne dla nowych projektów

`Projekty → Domyślne dla nowych projektów → Skonfiguruj…` zapisuje lokalny szablon skilli, serwerów MCP i dokumentów. `Dodaj projekt` oraz `Dodaj wiele` otwierają się z tym wyborem, ale możesz go dowolnie zmienić przed zapisem. Zmiana domyślnych nie wpływa na istniejące projekty.

```bash
swift run agentbox sync global --skills seo-audit,docx --tags seo --tools claude,opencode
swift run agentbox sync all
```

`Ustawienia → Backup i odzyskiwanie` pozwala przywrócić snapshot metadanych biblioteki albo pełny backup lokalny. Pliki w folderach projektów odtwarza się ponowną synchronizacją, a czyści przez `Usuń i posprzątaj pliki`. Przed przywróceniem Agentbox automatycznie zachowuje aktualny stan.

### Wartości MCP

Wartości MCP są zapisywane lokalnie wprost w `mcp.json`, a pełny backup lokalny obejmuje ten plik. Podczas synchronizacji wartości mogą zostać zapisane jawnie w plikach projektu.

Jeśli projekt jest repozytorium Git, Agentbox dopisuje do lokalnego `.git/info/exclude`:

```text
.mcp.json
.codex/config.toml
opencode.json
opencode.jsonc
```

Nie usuwa to pliku, który został już wcześniej dodany do Git. Zawsze warto sprawdzić `git status` oraz historię repozytorium.

### OAuth

Serwery logujące się przez OAuth zapisuje się tylko jako URL. Logowanie przez przeglądarkę wykonuje Claude, Codex albo OpenCode. Token OAuth znajduje się w magazynie danego klienta, nie w Agentbox, i nie jest nadpisywany podczas synchronizacji. Każde narzędzie uwierzytelnia się osobno.

### Serwery klientów (Codex i Claude Code)

Codex CLI, jego wtyczka IDE i aplikacja ChatGPT Desktop dzielą jeden plik `~/.codex/config.toml` — serwer dodany w którymkolwiek z nich ładuje się automatycznie w każdym projekcie Codexa. Claude Code ma analogiczny mechanizm: serwer dodany w zasięgu `user` (`~/.claude.json`) też trafia wszędzie. Agentbox nie zarządza tymi plikami, tylko je odczytuje i pozwala wyłączyć wybrany serwer dla jednego projektu. W aplikacji otwiera to `Projekty → Serwery klientów…` (`agentbox mcp global list/disable/enable <projekt>` — patrz [instrukcja CLI](docs/CLI.md#globalne-serwery-codex-i-claude-code)). Dla Codexa Agentbox dopisuje samo `enabled = false` bez powtarzania `command`/`args`; dla Claude Code nazwa trafia do `disabledMcpServers` w `.claude/settings.local.json`, obok pozostałych ustawień w tym pliku.

### CLI MCP

```bash
swift run agentbox mcp server add context7 --command npx --args "-y,@upstash/context7-mcp"
swift run agentbox mcp server add docsearch --url https://mcp.example.com/mcp
swift run agentbox mcp assign website --servers context7,docsearch --tags seo
swift run agentbox mcp preview website
swift run agentbox mcp sync website
```

CLI rozdziela synchronizację skilli (`agentbox sync project`) i MCP (`agentbox mcp sync`). GUI łączy je w `Synchronizuj wszystko`.

## Dokumenty (AGENTS.md / CLAUDE.md)

Zakładka `Dokumenty` w `Bibliotece` zbiera współdzielone teksty, przypisywane do projektów wprost albo przez tag — dokładnie tak samo jak skille i serwery MCP. Każdy dokument ma swój tekst, zapisywany raz.

Zsynchronizowany dokument trafia zawsze jako **para plików w katalogu głównym projektu**: `AGENTS.md` z pełną treścią i `CLAUDE.md` wygenerowany automatycznie jako jedna linijka — `@AGENTS.md`. To udokumentowany mechanizm importu plików w Claude Code (Claude Code czyta `CLAUDE.md`, nie czyta `AGENTS.md` samodzielnie), więc jeden tekst obsługuje oba bez ręcznego duplikowania go. `CLAUDE.md` nie jest edytowalny osobno.

Do jednego projektu może pasować tylko jeden dokument naraz — `AGENTS.md` ma jedną treść. Więcej niż jedno dopasowanie przez tagi zatrzymuje synchronizację jako konflikt, zamiast wybierać dowolne.

Synchronizacja nadpisuje cały plik, tak jak katalog skilla. Ręcznie napisany `AGENTS.md` albo `CLAUDE.md`, którym Agentbox jeszcze nie zarządza, blokuje zapis zamiast zostać nadpisany — ten sam mechanizm ochrony co przy nieznanym katalogu skilla czy ręcznym wpisie MCP. Wyjątkiem jest plik identyczny bajt w bajt z treścią dokumentu: zostaje przejęty bez pytania.

```bash
swift run agentbox docs new standard --tags backend --file agents.md
swift run agentbox docs assign website --docs standard --tags backend
swift run agentbox docs preview website
swift run agentbox docs sync website
```

Przed zapisem danych Agentbox tworzy także lokalny snapshot `catalog.json`, `projects.local.json`, `selections.json`, `mcp.json` i `docs.json` w `.agentbox-snapshots/`. Zachowuje 10 ostatnich snapshotów; folder snapshotów nie jest częścią pełnych kopii.

## Pełny backup lokalny

Powstaje automatycznie raz dziennie (dopóki włączona jest automatyzacja w `Ustawienia → Backup i odzyskiwanie → Automatyzacja`), a przycisk `Utwórz teraz` robi to samo na żądanie, np. przed ryzykowną operacją. Czytelny folder powstaje w `backups/full/` i zawiera skille, projekty, lokalne ścieżki oraz pełną konfigurację MCP. Kopia zawiera jawne hasła i tokeny, nie jest szyfrowana, dlatego należy chronić ją jak plik z hasłami. Zachowywanych jest 14 ostatnich kopii, starsze są usuwane automatycznie.

## Ograniczenia i bezpieczeństwo

- `mcp.json` może zawierać jawne hasła i tokeny oraz nie jest szyfrowany.
- Podgląd oraz wynikowe pliki MCP mogą zawierać jawne sekrety.
- Agentbox nie uruchamia ani nie testuje serwerów MCP.
- Agentbox nie przeprowadza OAuth i nie zarządza sesją klienta.
- Usunięcie projektu nigdy nie usuwa folderu projektu; sprzątanie plików obejmuje wyłącznie pozycje z manifestów Agentbox.
- Skille pochodzące z Git są w aplikacji tylko do odczytu.
- Aktualizacje Git są wykonywane wyłącznie na żądanie.

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
10. Utwórz pełny backup lokalny biblioteki.
