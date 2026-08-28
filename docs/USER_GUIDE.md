# Agentbox — instrukcja użytkownika

## Instalacja CLI

Wersja DMG zawiera aplikację oraz polecenie terminalowe. Po przeniesieniu Agentbox do folderu `Aplikacje` otwórz `Ustawienia → Wiersz poleceń (CLI)` i wybierz `Zainstaluj CLI`. Agentbox utworzy dowiązanie `/usr/local/bin/agentbox`; macOS może poprosić o hasło administratora. Symlink wskazuje plik wewnątrz aplikacji, dlatego aktualizacja Agentbox aktualizuje również CLI.

Po instalacji otwórz nowe okno Terminala i wykonaj np. `agentbox project list`. Polecenie `agentbox update --all` sprawdza i pobiera wszystkie dostępne aktualizacje skilli Git do biblioteki. Nie kopiuje ich automatycznie do projektów — użyj potem `agentbox sync project <nazwa>` albo `Synchronizuj wszystko` w GUI. Komenda `agentbox refresh` łączy aktualizację skilli, pełny backup lokalny, backup Git i transakcyjną synchronizację wszystkich projektów w jeden workflow. Pełna lista poleceń znajduje się w [instrukcji CLI](CLI.md).

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
- `Tylko na tym Macu` — wartość trafia do lokalnego `mcp-secrets.json`, który jest wyłączony z backupu Git. Plik nie jest obecnie szyfrowany.
- `Zwykła wartość` — wartość trafia do `mcp.json` i może znaleźć się w backupie Git.

Automatyczne rozpoznawanie jest tylko sugestią. Agentbox uznaje za podejrzane nazwy lub wartości zawierające między innymi `token`, `password`, `api_key`, `cookie`, `secret`, `authorization` lub `bearer`. Nietypowo nazwany sekret może zostać błędnie uznany za zwykłą wartość, dlatego klasyfikację należy sprawdzić.

Sekret przechowywany poza backupem biblioteki może zostać zapisany jawnie w wynikowym pliku MCP projektu, jeśli format klienta tego wymaga. Przed synchronizacją Agentbox pokazuje pełną treść wynikowych konfiguracji. Preferuj zmienne systemowe, jeśli klient je obsługuje.

Po imporcie klasyfikacją nadal można zarządzać w `MCP → Szczegóły`. Sekcja `Zmienne i nagłówki` pokazuje każdą wartość wprost, łącznie z sekretami — Agentbox jest lokalną aplikacją dla jednej osoby, więc nie ma powodu jej maskować na ekranie; typ pola decyduje wyłącznie o tym, czy wartość trafia do backupu Git. Tam samo `MCP → Szczegóły → JSON` daje pełną konfigurację jednego serwera jako tekst do ręcznej edycji i zastępuje wtedy sekcję `Zmienne i nagłówki`, zamiast pokazywać ją obok. Zapis z JSON-a klasyfikuje każde pole od nowa tą samą heurystyką co import.

`Edytuj wszystko jako JSON` na liście serwerów otwiera osobny, prosty widok dla całej konfiguracji naraz: popraw i `Zapisz`, bez kroku analizy i zaznaczania — to edycja własnej konfiguracji, nie import czegoś nowego. Checkboxy przy serwerach pozwalają zaznaczyć kilka naraz i dodać im tagi jedną operacją, tak jak w Bibliotece.

## Podgląd i synchronizacja

### Stan projektów

`Projekty → Sprawdź stan` sprawdza wszystkie projekty naraz i pokazuje odznakę przy każdym z nich:

- **Aktualny** — pliki projektu odpowiadają bibliotece,
- **Do synchronizacji +N ~N -N** — tyle skilli i wpisów MCP zostanie dodanych, odświeżonych i usuniętych,
- **Zablokowany** — w projekcie leży katalog skilla albo wpis MCP, którego Agentbox nie zarządza; najedź kursorem, aby zobaczyć powód,
- **Brak folderu** — katalog projektu zniknął z dysku.

Skill liczy się jako nieaktualny, gdy jego wersja w bibliotece jest nowsza niż ta zapisana w manifeście projektu, albo gdy jego katalog zniknął z projektu. Skille, które są aktualne, nie pojawiają się w żadnym z liczników.

### Pisanie własnego skilla

`Skille → Napisz własny` tworzy skill bez zakładania katalogu na dysku i bez repozytorium. Podaj nazwę (identyfikator podpowiada się sam), opcjonalny opis i tagi, a treść wpisz albo wklej w polu poniżej. Agentbox dopisze nagłówek YAML z nazwą i opisem. Jeśli wklejona treść zaczyna się od bloku `---`, jest traktowana jak gotowy `SKILL.md` i zapisywana bez zmian — pola nazwy i opisu są wtedy nieaktywne.

Tak utworzony skill jest lokalny, więc później można go poprawiać w aplikacji jak każdy skill dodany z dysku.

### Edycja skilli

Skille dodane z dysku i napisane w aplikacji można edytować bezpośrednio w aplikacji: wybierz skill i kliknij `Edytuj SKILL.md`. Zapis aktualizuje kopię w bibliotece i od razu oznacza wszystkie projekty z tym skillem jako nieaktualne, więc widać, gdzie trzeba uruchomić synchronizację.

Skille pochodzące z Git są tylko do odczytu. `Aktualizuj` zastępuje taki skill zawartością repozytorium, więc zmiana zrobiona w aplikacji zniknęłaby przy najbliższej aktualizacji. Aby zmienić taki skill, zmodyfikuj repozytorium źródłowe.

### Przejmowanie skilli z projektu

Jeśli w projekcie leży ręcznie napisany katalog ze `SKILL.md`, którego nie ma w bibliotece, wybierz `⋯ → Przejmij skille z projektu…`. Agentbox skopiuje wskazane katalogi do biblioteki jako skille lokalne — nic nie znika z projektu. To jest sposób na odblokowanie projektu ze statusem `Zablokowany` bez kasowania własnej pracy. Przejęty skill można od razu przypisać do projektów — także tego, z którego pochodzi: jego katalog jest identyczny z kopią biblioteczną, więc pierwsza synchronizacja przejmuje go pod zarząd Agentbox zamiast zgłaszać konflikt.

### Skille, których Agentbox nie zarządza

Agentbox usuwa i zastępuje wyłącznie katalogi wymienione w swoim manifeście `.skillbox.json`. Jeśli w katalogu docelowym leży katalog skilla o tej samej nazwie, którego w manifeście nie ma — na przykład skill napisany ręcznie w projekcie — synchronizacja zatrzymuje się z komunikatem `Konflikt skilla` i nie zapisuje niczego. Usuń ten katalog albo zmień nazwę skilla w bibliotece, jeśli ma go zastąpić. Ta sama zasada chroni ręcznie dodane serwery MCP oraz ręcznie napisane `AGENTS.md`/`CLAUDE.md` — z jednym wyjątkiem: plik identyczny bajt w bajt z treścią przypisanego dokumentu jest przejmowany bez pytania, zamiast blokować synchronizację.

### Wynik synchronizacji wszystkich projektów

`Synchronizuj wszystkie projekty` najpierw liczy plan dla wszystkich projektów i dopiero potem zapisuje. Każdy projekt jest zapisywany transakcyjnie, z własnym backupem. Pierwszy błąd zatrzymuje serię, a okno pokazuje wynik dla każdego projektu osobno: zsynchronizowany, cofnięty do stanu sprzed zmiany albo pominięty. Dzięki temu po błędzie zawsze wiadomo, które projekty zostały zmienione.

### Wybór MCP w projekcie

Serwery MCP wybiera się tak samo jak skille: pojedynczo albo dynamicznie według tagów. Oba sposoby można łączyć, a projekt może korzystać równocześnie z dowolnej liczby serwerów, również takich, które wcześniej były traktowane jako wzajemnie wykluczające się warianty.

Tagi dodaje się w szczegółach serwera MCP. Menu `Używane tagi` pokazuje istniejące wartości, co pomaga zachować jednolite nazwy. To samo menu jest dostępne podczas tagowania pojedynczych i wielu skilli. Wielkość liter nie ma znaczenia — tagi są zapisywane małymi literami, a `SEO` i `seo` to ten sam tag. Biblioteka ze starymi przypisaniami presetów (usuniętych jako funkcja w 0.3.1) migruje je automatycznie do bezpośredniego wyboru serwerów przy pierwszym otwarciu — bez utraty przypisań i bez żadnej akcji ze strony użytkownika.

### MCP globalne

Codex CLI, jego wtyczka IDE i aplikacja ChatGPT Desktop dzielą jeden plik `~/.codex/config.toml` — serwer dodany w którymkolwiek z nich ładuje się automatycznie w każdym projekcie Codexa. Claude Code ma analogiczny mechanizm: serwer dodany w zasięgu `user` (`~/.claude.json`) też trafia wszędzie. Zakładka `MCP globalne` w pasku bocznym pokazuje te serwery od strony narzędzia — po jednym wierszu na serwer, rozwijalnym do listy folderów i projektów, które go widzą.

Agentbox nie zarządza tymi plikami i niczego w nich nie nadpisuje — tylko je czyta. Odznaczenie folderu albo projektu przy serwerze zapisuje w bibliotece lokalny override: dla Codexa to samo `enabled = false` w `.codex/config.toml`, bez powtarzania `command`/`args`; dla Claude Code — nazwa w `disabledMcpServers` w `.claude/settings.local.json`, obok pozostałych ustawień w tym pliku. Sam przełącznik zapisuje tylko wybór; `Synchronizuj` przy każdym wierszu zapisuje zmianę na dysku dla tego jednego folderu/projektu, a `Synchronizuj wszystkie projekty` na górze zakładki robi to dla całej listy naraz, z tym samym podglądem i transakcją co w `Projekty`.

Po rozwinięciu serwera folder ze wspólnymi ustawieniami (ikona ⚙️ na liście `Projekty`) pokazuje **każdy** należący do niego projekt osobno, z własnym checkboxem — nie jeden zbiorczy wiersz. Projekt, który dziś dziedziczy ustawienia folderu, ma plakietkę `dziedziczy z folderu`, a jego checkbox pokazuje aktualny, wspólny stan. Odznaczenie takiego projektu pyta o potwierdzenie: to nie jest osobny przełącznik tylko dla tego serwera, tylko ten sam mechanizm co `Własne ustawienia` w edytorze projektu — projekt zaczyna od dokładnie tego, co ma dziś (skille, serwery MCP, dokument, i to co folder akurat wyłączał globalnie), ale przestaje automatycznie dostawać przyszłe zmiany folderu. Projekty, które tylko leżą w jednym katalogu bez wspólnych ustawień, są pogrupowane pod nazwą tego katalogu wyłącznie wizualnie — każdy zawsze miał własny, niezależny przełącznik.

Po rozwinięciu serwera pierwsza pozycja to `Wyłączaj w nowych projektach i folderach`. Wyłączanie globalnego serwera jest z natury per projekt, więc bez tej opcji projekt dodany za miesiąc znów widziałby go jako aktywny i trzeba by pamiętać o ponownym kliknięciu `Wyłącz wszędzie`. Zaznaczenie nie zmienia niczego w projektach, które już istnieją — decyduje wyłącznie o tym, z czym startuje następny.

Przy nazwie każdego serwera są też dwa linki — `Wyłącz wszędzie` i `Włącz wszędzie` — które stosują ten sam wybór do wszystkich folderów i samodzielnych projektów naraz, bez klikania każdego checkboxa osobno. Działają na poziomie folderów (nie forsują `Własnych ustawień` na każdym projekcie z osobna) — dokładnie odwrotność pojedynczego odznaczenia opisanego wyżej.

### Wybór dokumentu w projekcie

Dokument wybiera się jednym z dwóch sposobów: wprost z listy albo dynamicznie przez tag — nigdy oboma naraz w sposób, który dawałby więcej niż jedno dopasowanie. `AGENTS.md` ma tylko jedną treść, więc jeśli tagi wciągnęłyby dwa różne dokumenty do tego samego projektu, synchronizacja zatrzymuje się z komunikatem `Konflikt dokumentu` zamiast wybierać dowolny z nich — edytor projektu ostrzega o tym już przy zaznaczaniu tagów.

Zsynchronizowany dokument ląduje jako `AGENTS.md` (pełna treść) i `CLAUDE.md` (jednolinijkowy, wygenerowany import `@AGENTS.md`) w katalogu głównym projektu, niezależnie od tego, jakie narzędzia (Claude/Codex/OpenCode) ma projekt zaznaczone. `CLAUDE.md` nie edytuje się osobno — Claude Code czyta go i przez import wczytuje treść `AGENTS.md`, więc jeden tekst wystarcza obu.

### Wykluczenia w projekcie

Projekt może wciągać skille tagiem i jednocześnie pomijać wybrane pozycje. W edytorze projektu zaznaczenie tagu — skilla albo MCP — od razu zaznacza i blokuje odpowiednie pozycje na liście `Pojedyncze skille`/`Pojedyncze serwery MCP`, więc widać, co wchodzi przez tag, bez otwierania osobnej listy. Tag ma pierwszeństwo także wtedy, gdy pozycja była wcześniej zaznaczona ręcznie — wygląda wtedy identycznie jak każda inna wciągnięta tagiem. Odznaczenie tagu przed zapisem przywraca zwykłe zaznaczenie; po zapisie pozycję ma już tag i to on decyduje, czy wchodzi do projektu. Sekcja `Wykluczenia` pokazuje te same skille jeszcze raz — zaznaczenie skilla tam pomija go w tym jednym projekcie. Skille wybrane tylko pojedynczo, bez pasującego tagu, usuwa się po prostu odznaczając je na liście.

### Usuwanie projektu i sprzątanie plików

Usunięcie projektu daje dwie możliwości. `Usuń tylko z Agentbox` zostawia folder projektu nietknięty. `Usuń i posprzątaj pliki w projekcie` dodatkowo kasuje katalogi skilli, wpisy MCP i dokument `AGENTS.md`/`CLAUDE.md` wymienione w manifestach Agentbox — wyłącznie je. Plik konfiguracyjny, który w całości pochodził z Agentbox, znika razem z wpisami; ręcznie dodane skille, serwery MCP i pliki dokumentów zostają. Przed sprzątaniem powstaje backup, który można cofnąć w sekcji `Backup`.

Pliki i manifesty powstają tylko wtedy, gdy projekt ma co synchronizować — projekt bez wybranych skilli, serwerów MCP i dokumentu pozostaje nietknięty, a odznaczenie narzędzia sprząta jego pliki skilli/MCP przy kolejnej synchronizacji.

### Ochrona przez .gitignore projektu

W edytorze projektu można włączyć `Dopisuj wygenerowane pliki MCP do .gitignore projektu`. `.git/info/exclude`, którego Agentbox używa domyślnie, chroni tylko ten jeden klon — kolega z zespołu, który sklonuje repozytorium, nie jest chroniony wcale. `.gitignore` jedzie z repozytorium, więc obejmuje wszystkich. Agentbox dopisuje wyłącznie własny, oznaczony blok i nigdy nie usuwa istniejących wpisów. Opcja jest domyślnie włączona dla nowych projektów i wyłączona dla tych utworzonych wcześniej.

### Skille globalne

Sekcja `Globalne` synchronizuje wybrane skille do katalogu użytkownika, a nie do projektu. Są wtedy widoczne we wszystkich sesjach danego klienta:

- Claude Code — `~/.claude/skills`,
- Codex — `~/.codex/skills`,
- OpenCode — `~/.config/opencode/skills`.

Zaznacz narzędzia, a następnie pojedyncze skille lub tagi dynamiczne. `Zapisz wybór` zapamiętuje ustawienie w `projects.local.json`, `Odśwież podgląd` pokazuje planowane dodania, aktualizacje i usunięcia, a `Synchronizuj globalnie` zapisuje zmiany. Odznaczenie skilla usuwa go z katalogu użytkownika przy kolejnej synchronizacji — również tutaj usuwane są wyłącznie katalogi z manifestu Agentbox.

### Dodawanie wielu projektów

W sekcji `Projekty` wybierz `Dodaj wiele`, a następnie wskaż folder nadrzędny. Agentbox pokaże jego bezpośrednie, nieukryte podfoldery. Zaznacz projekty i ustaw wspólne narzędzia, pojedyncze skille i MCP, dynamiczne tagi obu typów, wykluczenia oraz opcję `.gitignore`. Podfolder zapisany już jako projekt jest oznaczony i nie można dodać go ponownie.

### Ustawienia folderu nadrzędnego

Domyślnie ustawienia z `Dodaj wiele` zapisują się **na folderze nadrzędnym**, a jego podfoldery je dziedziczą. Zmiana w folderze obejmuje od razu wszystkie projekty, które z niego korzystają — nie trzeba edytować każdego z osobna. Ustawienia folderu otwiera przycisk `Ustawienia folderu` w nagłówku grupy na liście projektów.

Projekty dodane wcześniej — pojedynczo albo przed pojawieniem się folderów nadrzędnych — też mogą dostać wspólne ustawienia. W nagłówku ich grupy jest przycisk `Wspólne ustawienia…`. Formularz startuje od sumy tego, czego projekty w folderze już używają, więc utworzenie folderu niczego nikomu nie zabiera, a przy każdym projekcie widać, co dokładnie się zmieni (`bez zmian`, `+2 skilli`, `−1 MCP`). Odznaczony projekt zostaje w folderze, ale zachowuje własne ustawienia.

Pojedynczy projekt może wyłamać się z tego schematu: w jego edytorze przełącznik `Skąd projekt bierze ustawienia` przełącza między `Z folderu` a `Własne dla tego projektu`. Formularz startuje wtedy od tego, co projekt dostawał z folderu, więc odejście od wspólnych ustawień nic nie zmienia, dopóki czegoś nie poprawisz. Na liście projektów widać obie sytuacje: projekt, który dziedziczy z folderu, ma przy nazwie małą strzałkę z podpowiedzią; projekt, który się wyłamał, ma zamiast niej pomarańczową plakietkę `Własne ustawienia` — od razu widać, że zmiana w folderze nadrzędnym go nie obejmie.

Odznaczenie `Zapisz ustawienia na folderze nadrzędnym` przy dodawaniu wraca do dawnego zachowania: każdy projekt dostaje własną kopię ustawień, bez dziedziczenia.

Usunięcie ustawień folderu (kosz w nagłówku grupy) nie rusza projektów. Każdy, który dziedziczył, dostaje kopię tego, co dotąd dostawał — łącznie z przypisaniami MCP — więc do repozytoriów trafia dokładnie to samo co przed usunięciem.

### Nowe podfoldery

Folder nadrzędny z włączoną opcją `Pytaj, gdy w tym folderze pojawi się nowy podfolder` jest sprawdzany:

- przy uruchomieniu aplikacji,
- po każdym powrocie do Agentbox z innej aplikacji — repozytoria klonuje się w terminalu, więc nowy podfolder czeka już po przełączeniu okna,
- po każdej zmianie danych w aplikacji,
- na żądanie, przyciskiem `Sprawdź stan` w sekcji `Projekty`.

Wykrywanie jest własnością folderu nadrzędnego, nie listy projektów: dopóki folder nie istnieje, nie ma czego skanować. Projekty pogrupowane po ścieżce dostają go przyciskiem `Wspólne ustawienia…` w nagłówku grupy.

Podfoldery, które leżą w folderze w chwili jego tworzenia i nie stają się projektami, są uznawane za znane — odznaczenie podfolderu przy dodawaniu jest odpowiedzią, a nie odłożonym pytaniem. Wyłącza to opcja `Pytaj tylko o podfoldery, które pojawią się od teraz`, a `Przywróć pominięte` w ustawieniach folderu przywraca je wszystkie.

Nowy podfolder — na przykład świeżo sklonowane repozytorium — pojawia się jako baner nad listą projektów, a liczba wykrytych folderów jest widoczna jako plakietka przy `Projekty` w menu bocznym. `Przejrzyj…` otwiera listę wykrytych folderów, w której można:

- `Dodaj i synchronizuj` — dodaje projekty i od razu synchronizuje je ustawieniami folderu,
- `Dodaj bez synchronizacji` — dodaje projekty i zostawia synchronizację na później,
- `Pomijaj zaznaczone` — zapamiętuje odmowę, więc Agentbox nie zapyta o te foldery ponownie,
- `Później` — zostawia pytanie na następny raz.

Usunięcie projektu należącego do obserwowanego folderu jest traktowane jak odmowa: jego podfolder nie wraca jako propozycja. Listę pominiętych folderów czyści przycisk `Przywróć pominięte` w ustawieniach folderu.

Lista projektów grupuje projekty według folderu nadrzędnego, a pozostałe — według ich bezpośredniego folderu — i pokazuje pełną ścieżkę grupy. Nagłówek zwija pojedynczą grupę, a menu pod listą pozwala rozwinąć lub zwinąć wszystkie. Przycisk `Synchronizuj wszystkie projekty` tworzy wspólny podgląd całej listy przed pierwszym zapisem. Następnie synchronizuje projekty kolejno; każdy z nich zachowuje własny backup, transakcyjny zapis skilli i MCP oraz rollback w razie błędu.

Podgląd projektu pokazuje osobno dla Claude, Codex i OpenCode:

- docelowy katalog skilli;
- skille dodawane, ponownie zapisywane i usuwane;
- serwery MCP dodawane i usuwane;
- pełną wynikową treść plików MCP.

Synchronizacja skilli i MCP jest jedną operacją. Przed zapisem Agentbox tworzy backup zarządzanych katalogów i plików w bibliotece, w `backups/projects/<id-projektu>/`. Jeśli którykolwiek etap zakończy się błędem, wcześniejsze zmiany tej operacji są automatycznie wycofywane. Zachowywanych jest 10 ostatnich backupów.

Obce skille i ręczne wpisy MCP nie są przejmowane przez Agentbox. Konflikt nazwy z ręcznym wpisem zatrzymuje operację przed zapisem.

## Historia operacji i błędy

Przycisk z ikoną historii na pasku narzędzi otwiera listę sukcesów i błędów z bieżącej sesji. Komunikat może zniknąć z dolnej części okna, ale pozostaje w historii i można skopiować jego treść.

W przypadku błędu synchronizacji:

1. otwórz historię operacji i skopiuj komunikat;
2. sprawdź, czy folder projektu istnieje i jest zapisywalny;
3. usuń konflikt ręcznego wpisu MCP albo zmień nazwę serwera;
4. ponownie otwórz podgląd — Agentbox nie zapisuje planu, który nie przechodzi walidacji.

## Odzyskiwanie

Odzyskiwanie ma teraz wspólne miejsce z resztą backupów w sekcji `Backup`, zamiast osobnej pozycji w pasku bocznym — to jedno pytanie („jak chronię i odzyskuję dane”), nie dwa.

Przed zmianą plików danych Agentbox zachowuje rotacyjne snapshoty w:

```text
<biblioteka>/.agentbox-snapshots/
```

Snapshot zawiera bieżące wersje `catalog.json`, `projects.local.json` i `mcp.json`. Zachowywanych jest 10 ostatnich snapshotów. Sekrety nie są do nich kopiowane. Folder snapshotów jest wyłączony z backupu Git.

W sekcji `Backup → Snapshoty biblioteki` można wybrać kopię na podstawie daty i przywrócić zapisane w niej pliki. Katalog `skills/` i `mcp-secrets.json` nie są zmieniane. Przed przywróceniem Agentbox tworzy snapshot aktualnego stanu.

### Gdzie leżą kopie

Kopia sprzed zapisu istnieje wyłącznie przez czas trwania jednej synchronizacji, w katalogu tymczasowym, i jest kasowana niezależnie od tego, czy zapis się powiódł. Służy do jednego: cofnięcia zmian, gdy operacja padnie w połowie.

Agentbox nie prowadzi historii kopii w folderach projektów. Nie jest potrzebna, bo biblioteka jest źródłem prawdy, manifesty mówią, co należy do Agentboxa, a stan projektu odtwarza się dwoma ruchami: `Usuń i posprzątaj pliki` (albo `agentbox project unsync`) czyści to, co Agentbox tam zapisał, a ponowna synchronizacja odtwarza to z biblioteki.

W folderze projektu zostają wyłącznie manifesty własności: `.skillbox/mcp-manifest.json` i `.skillbox.json` w każdym katalogu skilli. To małe pliki JSON odpowiadające na pytanie „które wpisy tutaj są moje” — bez nich Agentbox nadpisałby ręcznie dodane skille i serwery.

Wersje do 0.7.0 zostawiały historię kopii w `<projekt>/.skillbox/sync-backups/` i `mcp-backups/`. Przy najbliższej synchronizacji te katalogi są usuwane z repozytorium.

Projekt, w którym nic się nie zmieniło, jest pomijany — nic nie jest zapisywane, a wynik to `Bez zmian`.

Ta część sekcji `Backup` dotyczy wyłącznie biblioteki: snapshotów metadanych i pełnego backupu lokalnego.

Backup Git obejmuje `catalog.json`, `mcp.json` i `skills/`. Nie obejmuje lokalnych ścieżek projektów ani sekretów. Git zapewnia długoterminową historię biblioteki, natomiast snapshoty chronią ostatni stan przed przypadkowym lub uszkodzonym zapisem.

### Pełny backup lokalny

To jedyny mechanizm chroniący projekty i sekrety — ani backup Git, ani snapshoty ich nie obejmują. Powstaje automatycznie raz dziennie, dopóki włączona jest automatyzacja w `Backup → Automatyzacja` (ten sam przełącznik co dla commitów Git); `Backup → Utwórz teraz` robi to samo na żądanie. Tworzy czytelną kopię w `<biblioteka>/backups/full/<data>/`. Zawiera `catalog.json`, `projects.local.json`, `mcp.json`, `mcp-secrets.json`, metadane `backup.json` oraz cały katalog `skills/`. Obejmuje więc adresy Git skilli, lokalne ścieżki projektów, wszystkie MCP i sekrety.

Folder `backups/` jest wyłączony z Git. Pełny backup nie jest szyfrowany — nie umieszczaj go w chmurze ani repozytorium bez dodatkowego szyfrowania. Zachowywanych jest 14 ostatnich kopii; starsze są usuwane automatycznie, więc miejsce na dysku nie rośnie bez końca. Przed przywróceniem Agentbox waliduje wszystkie pliki JSON i katalog skilli, następnie zapisuje aktualny stan w `backups/restore-rollbacks/`. Nieudana operacja automatycznie odtwarza poprzednie dane. Z interfejsu można również usunąć wybraną pełną kopię po potwierdzeniu.

### Odtworzenie biblioteki ze zdalnego repozytorium

`Backup → Odtworzenie biblioteki ze zdalnego repozytorium` pobiera bibliotekę z repozytorium backupu. Służy przede wszystkim do konfiguracji nowego Maca albo odtworzenia biblioteki po awarii dysku.

Zastępowane są `catalog.json`, `mcp.json`, katalog `skills/` oraz `.gitignore`. **Nie** są zmieniane `projects.local.json` ani `mcp-secrets.json` — projekty, lokalne ścieżki i sekrety należą do tego Maca i nie trafiają do repozytorium. Przed zapisem Agentbox tworzy pełny backup lokalny, waliduje pliki JSON z repozytorium i przy błędzie odtwarza poprzedni stan. Klon zachowuje swoje `.git`, więc kolejne backupy wypychają do tego samego repozytorium.

Serwery MCP wymagające sekretów nie zadziałają od razu na nowym Maku — sekrety trzeba dostarczyć osobno, poza Gitem. Najszybciej: skopiuj `mcp-secrets.json` z ostatniego pełnego backupu starego Maca (`<biblioteka>/backups/full/<data>/mcp-secrets.json`) do folderu nowej biblioteki przez AirDrop albo inny bezpieczny kanał — jednorazowo, przy każdym nowym Maku.

Po odtworzeniu przypisz skille do projektów i uruchom synchronizację — pliki projektów nie są zmieniane automatycznie.

Jeśli problem dotyczy katalogu skilli lub długoterminowej historii konfiguracji, można również przywrócić odpowiedni commit Git.

## Pliki projektu i Git

Agentbox dopisuje generowane konfiguracje MCP oraz `.skillbox/` do lokalnego `.git/info/exclude`. Nie usuwa to pliku, który został wcześniej dodany do indeksu Git. Po pierwszej synchronizacji sprawdź:

```bash
git status
git ls-files .mcp.json .codex/config.toml opencode.json opencode.jsonc
```

Jeżeli któreś z tych poleceń pokaże plik zawierający sekret, usuń go z indeksu i sprawdź historię repozytorium.
