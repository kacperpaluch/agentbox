# Changelog

Wszystkie istotne zmiany w Agentbox są dokumentowane w tym pliku.

Format jest oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/). Projekt używa wersjonowania semantycznego od pierwszego stabilnego wydania.

## [Unreleased]

## [0.13.1] - 2026-08-27

### Zmieniono

- Projekt należący do obserwowanego folderu, który ma włączone własne ustawienia zamiast dziedziczyć je z folderu, jest teraz od razu widoczny na liście `Projekty` — plakietka „Własne ustawienia” przy nazwie, z podpowiedzią która przypomina, że zmiana w folderze go nie obejmie. Dotąd było to widać tylko po otwarciu edytora tego projektu.

## [0.13.0] - 2026-08-27

### Dodano

- Nowa sekcja „Dokumenty”: biblioteka współdzielonych tekstów `AGENTS.md`, tagowana i przypisywana do projektów tak samo jak skille i serwery MCP (wprost albo przez tag). `CLAUDE.md` nie trzeba pisać osobno — Agentbox generuje go automatycznie jako jednolinijkowy import `@AGENTS.md` (oficjalnie udokumentowany mechanizm Claude Code), więc jeden tekst obsługuje oba narzędzia bez duplikacji. Oba pliki zawsze synchronizują się razem, z tym samym pełnym nadpisaniem, backupem i rollbackiem co reszta projektu, i tą samą ochroną ręcznie napisanych plików przed nadpisaniem. CLI: `agentbox docs list|new|tag|delete|assign|preview|sync`.
- Skille i serwery MCP są teraz konsekwentnie sortowane alfabetycznie — w zakładkach Biblioteka/MCP oraz na wszystkich listach wyboru w edytorach projektów i folderów.

## [0.12.0] - 2026-08-27

### Dodano

- CLI: `agentbox delete <skill>`, `agentbox project remove <nazwa> [--clean]` i `agentbox mcp server remove <nazwa>` — dotąd usuwanie skilli, projektów i serwerów MCP było możliwe wyłącznie w GUI.
- Pełny backup lokalny powstaje teraz automatycznie raz dziennie (dopóki włączona jest automatyzacja w `Backup → Automatyzacja`), zamiast wymagać ręcznego kliknięcia. To jedyny mechanizm chroniący projekty i sekrety, więc łatwo było o nim zapomnieć. Zachowywanych jest 14 ostatnich kopii, starsze są usuwane automatycznie.
- `MCP → Importuj z JSON` ma teraz przycisk „Jaki format?” z przykładem wszystkich trzech obsługiwanych wariantów wklejanego JSON-a.
- Dokumentacja odtwarzania biblioteki na nowym Macu opisuje wprost, jak dostarczyć `mcp-secrets.json` poza Gitem (kopia z pełnego backupu przez AirDrop) — sekrety MCP celowo nie trafiają do repozytorium backupu, więc dotąd trzeba było się domyślić, że wymagają osobnego kroku.

### Usunięto

- Asystent AI do generowania configu MCP z instrukcji (OpenAI/Anthropic) — rzadko używana funkcja, spory kawałek UI w Ustawieniach i w oknie importu. Import z gotowego JSON-a zostaje, teraz jako `Importuj z JSON`.
- Martwy kod po starych presetach MCP (`presets`, `projectPresetIDs`) i nieużywanych polach `group`/`profile` serwera MCP — pozostałość po funkcji usuniętej w 0.3.1, którą aplikacja dotąd bezcelowo dźwigała dalej. Biblioteki, które jeszcze mają stare przypisania przez presety, migrują się automatycznie przy pierwszym otwarciu (przypisanie trafia do bezpośrednich serwerów projektu, nic nie znika).
- Ramowanie „MVP” w README — projekt ma już kilkanaście wydań i codzienne użycie.

## [0.11.2] - 2026-08-27

### Zmieniono

- Przegląd wizualny GUI: wspólna skala odstępów i ról typograficznych (`DesignSystem.swift`), jeden neutralny styl tagów zamiast siedmiu losowych kolorów z hasha nazwy, wspólny komponent `MetaBadge` na drobne fakty (typ transportu, narzędzie) odróżniony od realnych statusów (aktualizacja, błąd synchronizacji). Wiersze list (skille, projekty, serwery MCP) mają teraz stały dwuliniowy układ — nazwa i jedna najważniejsza odznaka na górze, metadane i tagi niżej, akcje drugorzędne schowane w menu „⋯”. Biblioteka i MCP używają jednego paska akcji, który zamienia się w pasek zaznaczenia zamiast dokładać drugi rząd przycisków.
- Pasek boczny: „Biblioteka” nazywa się teraz „Skille” (tam faktycznie są skille), kolejność sekcji dopasowana do tego, jak często są otwierane (Skille, MCP, Globalne, Projekty, Backup, Ustawienia), a „Backup” i „Odzyskiwanie” scalone w jedną sekcję — to jedno pytanie („jak chronię i odzyskuję dane”) rozbite dotąd na dwie pozycje w menu i cztery różne mechanizmy.
- `Sources/SkillboxApp/main.swift` (1864 linii) rozbite na pliki per widok (`LibraryView.swift`, `ProjectsView.swift`, `ProjectEditors.swift`, `MCPView.swift`, `GlobalSyncView.swift`, `BackupView.swift`, `SettingsView.swift`, `SharedSheets.swift`, `App.swift`, `AppModel.swift`, `DesignSystem.swift`) — bez zmiany zachowania, tylko podział pliku.

## [0.11.1] - 2026-08-26

### Zmieniono

- Pasek filtrów w Bibliotece (tag, grupowanie, sortowanie, rozwijanie grup, sprawdzanie aktualizacji) zwinięty do jednego menu „Filtruj i sortuj” zamiast pięciu osobnych, zawsze widocznych kontrolek — ten sam wzorzec co „Uporządkuj” we Finderze czy Mailu. Wąska kolumna listy nie musi już mieścić ich wszystkich naraz, co usuwa obcinanie się etykiet przy typowej szerokości okna.

## [0.11.0] - 2026-08-26

### Dodano

- W zakładce MCP checkboxy przy serwerach pozwalają zaznaczyć kilka naraz i dodać im tagi jedną operacją — `Dodaj tagi (N)` w pasku akcji, tak samo jak w Bibliotece.

### Zmieniono

- `Edytuj wszystko jako JSON` zapisuje teraz jednym kliknięciem — bez kroku analizy, zaznaczania serwerów i klasyfikacji pól. Ta ceremonia zostaje tam, gdzie jest potrzebna: w `Importuj lub użyj AI`, czyli przy wklejaniu configu z zewnątrz.
- W trybie JSON edytora pojedynczego serwera znika sekcja `Zmienne i nagłówki` — te same wartości nie pokazują się już drugi raz w dwóch formatach naraz.
- Zakładka Globalne korzysta teraz z tych samych komponentów wyboru skilli i tagów co Projekty, foldery nadrzędne i `Dodaj wiele` — spójny wygląd zamiast osobnej implementacji.
- Ujednolicono nazwę przycisku czyszczenia zaznaczenia (`Wyczyść`) we wszystkich miejscach, gdzie można zaznaczać wiele pozycji.

### Naprawiono

- Okno dodawania tagów pokazywało „Wybrano N skilli” nawet przy zaznaczeniu serwerów MCP.

## [0.10.0] - 2026-08-26

### Dodano

- `MCP → Szczegóły → JSON` edytuje `command`/`args`/`url`/`env`/`headers` jednego serwera jako zwykły tekst, a `Edytuj wszystko jako JSON` na liście serwerów robi to samo dla całej konfiguracji naraz, wypełnione aktualnym stanem. Zapis nadpisuje po nazwie serwery, których dotyczy, i zostawia resztę bez zmian.
- Pola MCP — łącznie z sekretami — pokazują teraz wartość wprost zamiast maski `••••••••`. Agentbox jest lokalną aplikacją dla jednej osoby, więc nie ma powodu chować własnych danych przed sobą; typ pola (`Zmienna systemowa` / `Tylko na tym Macu` / `Zwykła wartość`) nadal decyduje, czy wartość może trafić do backupu Git, teraz widoczne wprost w samej nazwie typu zamiast w osobnym ostrzeżeniu.

### Naprawiono

- Import repozytorium Git z więcej niż jednym konfliktującym skillem tracił cały import: jeden identyfikator kolidujący z istniejącym skillem z innego źródła przerywał pętlę, zanim cokolwiek trafiło do zapisu, więc nawet poprawnie przetworzone wcześniej skille nigdy nie lądowały w bibliotece. Konfliktujący albo niepoprawny kandydat jest teraz pomijany z komunikatem, a reszta partii importuje się i zapisuje normalnie.
- Ponowne dodanie tego samego repozytorium Git innym, równoważnym zapisem adresu (np. z końcówką `.git` zamiast bez niej) było traktowane jak zupełnie inne źródło i kończyło się odrzuceniem jako duplikat zamiast aktualizacji.

## [0.9.5] - 2026-08-26

### Naprawiono

- Poprawka menu bocznego z 0.9.4 nadal nie pozwalała zmieniać sekcji: opcjonalne zaznaczenie listy dostało tagi o niewłaściwym, również opcjonalnym typie. Wiersze ponownie używają wartości `SectionKind`, której oczekuje `List(selection:)`.

## [0.9.4] - 2026-08-26

### Naprawiono

- Po dodaniu plakietki wykrytych projektów boczne menu przestało reagować na kliknięcia w sekcje, między innymi MCP, Backup i Ustawienia. Plakietka jest teraz zwykłym, warunkowym elementem wiersza i nie przechwytuje obszaru klikalnego nawigacji.

## [0.9.3] - 2026-08-26

### Naprawiono

- Przejęcie skilla z projektu nie odblokowywało synchronizacji tego projektu. Skill po `Przejmij skille z projektu…` był w bibliotece, ale jego katalog w projekcie nadal liczył się jako obcy — przypisanie przejętego skilla kończyło się błędem `istnieje i nie jest zarządzany przez Agentbox`, a projekt pokazywał status `Zablokowany`. Katalog identyczny bajt w bajt z kopią biblioteczną przechodzi teraz pod zarząd Agentbox przy pierwszej synchronizacji, dokładnie tak, jak obiecywała dokumentacja. Katalog o innej zawartości nadal zatrzymuje synchronizację. Pliki `.DS_Store` nie wpływają na porównanie.
- Synchronizacja tworzyła puste pliki w każdym projekcie, także bez wybranych skilli i serwerów MCP: `.mcp.json` z pustym `mcpServers`, `opencode.json`, `.codex/config.toml` z samymi znacznikami oraz puste manifesty. `Usuń i posprzątaj pliki` zostawiało je w repozytorium, wbrew własnej obietnicy. Pliki i manifesty powstają teraz tylko wtedy, gdy jest co do nich zapisać; puste szkielety pozostawione przez starsze wersje znikają przy najbliższej synchronizacji, a sprzątanie usuwa plik, który w całości pochodził z Agentbox. Wpisy użytkownika w tych plikach pozostają nietknięte, a plik, w którym Agentbox niczym nie zarządza, nie jest już przepisywany ani formatowany na nowo.
- Odznaczenie narzędzia w projekcie osierocało jego pliki: katalogi skilli, manifesty i wpisy MCP odznaczonego narzędzia zostawały w repozytorium na zawsze. Podgląd i synchronizacja obejmują teraz także narzędzia z pozostałym po sobie manifestem — najbliższa synchronizacja sprząta ich pliki, a `Usuń i posprzątaj pliki` czyści je razem z resztą.
- Wyszukiwarka w Bibliotece nie znajdowała skilla po nazwie, tylko po identyfikatorze i tagach — wbrew podpowiedzi `Nazwa lub tag` w polu wyszukiwania.

### Dodano

- Edytor serwera MCP ostrzega, gdy pole z zapisanym sekretem zmienia typ na `Zwykła wartość`: dotychczasowy sekret zostałby przeniesiony jawnym tekstem do `mcp.json`, który trafia do backupu Git.

## [0.9.2] - 2026-08-26

### Naprawiono

- Wykrywanie nowych podfolderów z 0.9.0 działało tylko przy uruchomieniu aplikacji i po zmianie danych. Repozytorium sklonowane przy otwartym Agentbox nie pojawiało się aż do restartu, a przycisk `Sprawdź stan` sprawdzał wyłącznie stan projektów względem biblioteki i nowych folderów nie szukał. Skanowanie odpala się teraz także po powrocie do aplikacji z innego okna — czyli dokładnie wtedy, gdy użytkownik wraca z terminala po `git clone` — oraz na żądanie przyciskiem `Sprawdź stan`.
- `Sprawdź stan` był nieaktywny, gdy na liście nie było jeszcze żadnego projektu. Folder nadrzędny bez projektów nie miał jak zaproponować swoich podfolderów; przycisk działa teraz, gdy jest choć jeden folder nadrzędny.

- Podfolder odznaczony w `Dodaj wiele` był proponowany ponownie zaraz po dodaniu, mimo że odznaczenie jest odpowiedzią, a nie odłożonym pytaniem. Podfoldery obecne w chwili tworzenia folderu nadrzędnego są teraz uznawane za znane; `nowy` znaczy `pojawił się od tej chwili`. Zachowanie wyłącza opcja `Pytaj tylko o podfoldery, które pojawią się od teraz`, a `Przywróć pominięte` przywraca je wszystkie.

### Dodano

- Liczba wykrytych podfolderów jest widoczna jako plakietka przy `Projekty` w menu bocznym, więc pytanie nie czeka niezauważone w zakładce, do której nikt akurat nie zagląda.

## [0.9.1] - 2026-08-26

### Naprawiono

- Wspólne ustawienia folderu nadrzędnego z 0.9.0 były nieosiągalne dla projektów dodanych wcześniej. Folder nadrzędny mogła utworzyć wyłącznie opcja `Dodaj wiele`, więc kto miał już projekty na liście, nie widział przycisku `Ustawienia folderu` i nie miał jak ustawić wspólnych skilli ani MCP. Nagłówek grupy projektów ma teraz przycisk `Wspólne ustawienia…`, który zamienia istniejący folder w nadrzędny. Formularz startuje od sumy tego, czego projekty w folderze już używają, a przy każdym z nich widać, co się zmieni; odznaczony projekt zostaje w folderze z własnymi ustawieniami.
- CLI: `agentbox project root-adopt <nazwa> <folder> [--skills a,b] [--tags x] [--keep-own projekt]`.

### Zmieniono

- `agentbox refresh` kończy się blokiem `PODSUMOWANIE` zamiast pojedynczej linii gubiącej się na końcu długiej listy. Blok pokazuje zaktualizowane skille, nazwę backupu lokalnego, skrót wyniku backupu Git i bilans projektów. Projekt cofnięty po błędzie oraz projekty pominięte po nim są teraz wymienione z nazwy — wcześniej widać je było wyłącznie w środku listy, więc długi przebieg mógł skończyć się wyglądając na udany.

## [0.9.0] - 2026-08-26

### Dodano

- Ustawienia wspólne dla folderu nadrzędnego. `Dodaj wiele` zapisuje teraz narzędzia, skille, tagi, serwery MCP, wykluczenia i opcję `.gitignore` na samym folderze, a jego podfoldery je dziedziczą — jedna zmiana obejmuje wszystkie projekty w folderze zamiast edycji każdego z osobna. Pojedynczy projekt może przejść na własne ustawienia przełącznikiem w swoim edytorze; formularz startuje wtedy od tego, co dotąd dziedziczył, więc samo odłączenie niczego nie zmienia. Odznaczenie opcji przy dodawaniu wraca do dawnego zachowania z kopią ustawień w każdym projekcie.
- Wykrywanie nowych podfolderów. Folder nadrzędny jest sprawdzany przy każdym odświeżeniu listy projektów, a nowy podfolder — na przykład świeżo sklonowane repozytorium — pojawia się jako pytanie nad listą: dodać i zsynchronizować, dodać bez synchronizacji, czy pomijać. Odmowa jest zapamiętywana, tak samo jak usunięcie projektu z obserwowanego folderu, więc to samo pytanie nie wraca przy każdym uruchomieniu.
- `Biblioteka → Napisz własny` tworzy skill bez zakładania katalogu na dysku i bez repozytorium: wystarczy wpisać albo wkleić treść. Agentbox dopisuje nagłówek YAML z nazwą i opisem, a wklejony plik z własnym blokiem `---` zapisuje bez zmian. Taki skill jest lokalny, więc pozostaje edytowalny w aplikacji.
- CLI: `agentbox new <id> [--name] [--description] [--tags] [--file plik|-]` oraz `agentbox project root-add|roots|scan|adopt-new|ignore-new|unignore`.

### Naprawiono

- Biblioteka w katalogu, którego ścieżkę system zapisuje inaczej po standaryzacji (np. `/private/tmp/...`), odrzucała edycję i usuwanie skilla komunikatem `Niebezpieczna ścieżka`. Sprawdzana jest teraz sama nazwa skilla, a nie wynik porównania dwóch różnie znormalizowanych ścieżek.

### Zmieniono

- Edytor projektu i formularz `Dodaj wiele` korzystają z tego samego zestawu ustawień, więc `Dodaj wiele` obsługuje teraz również wykluczenia i opcję `.gitignore`.
- `project set` i `mcp assign` odmawiają zmiany projektu korzystającego z ustawień folderu nadrzędnego zamiast zapisywać wybór, którego synchronizacja i tak nie czyta.

## [0.8.1] - 2026-08-25

### Naprawiono

- W edytorze projektu serwer MCP albo skill zaznaczony wcześniej ręcznie wyglądał inaczej niż taki sam wciągnięty tagiem: pozostawał zwykłym zaznaczeniem zamiast zablokowanej pozycji tagu. Żeby zobaczyć go jako wybranego przez tag, trzeba było odznaczyć wszystko i wybrać tag jeszcze raz. Teraz tag ma pierwszeństwo od razu, a ręczne zaznaczenie zostaje pod spodem i wraca po odznaczeniu tagu.
- Sekcja `Wykluczenia` pomijała skille, które były jednocześnie zaznaczone ręcznie i wciągane tagiem — po zablokowaniu ich pola nie było już jak usunąć takiego skilla z projektu. Wykluczenie zdejmuje teraz także ręczne zaznaczenie, więc w danych nie zostaje martwy wpis.
- Dopasowanie tagów w edytorze projektu ignoruje wielkość liter, tak jak robi to synchronizacja.

### Zmieniono

- Zapis projektu — z aplikacji i z CLI — nie trzyma już pojedynczych zaznaczeń skilli i serwerów MCP, które i tak wciąga wybrany tag, ani skilli wpisanych na listę wykluczeń. Do projektu wchodzi dokładnie to samo co wcześniej, ale po usunięciu tagu pozycja nie zostaje w projekcie przez zapomniane zaznaczenie sprzed tagowania. Stare przypisania czyszczą się przy najbliższym zapisie projektu.

## [0.8.0] - 2026-08-25

### Dodano

- W edytorze projektu zaznaczenie tagu — skilla albo MCP — zaznacza i blokuje od razu odpowiednie pozycje na liście `Pojedyncze skille`/`Pojedyncze serwery MCP`, więc widać, co dokładnie wchodzi przez tag, bez zaglądania do osobnej sekcji.

### Naprawiono

- Status projektów w zakładce `Projekty` nie był odświeżany po dodaniu tagu do skilla, edycji tagów serwera MCP ani dodaniu/usunięciu serwera — badge pokazywał stary stan (np. `Aktualny`), dopóki użytkownik nie kliknął `Sprawdź stan` albo nie zrobił czegoś bezpośrednio na projekcie. Sama synchronizacja zawsze liczyła się poprawnie na świeżo; teraz status odświeża się automatycznie po każdej takiej zmianie.

## [0.7.2] - 2026-08-24

### Naprawiono

- Tagi dopasowują się niezależnie od wielkości liter. Serwer MCP z tagiem `SEO` był cicho pomijany przy synchronizacji, bo przypisanie projektu zapisywało tag jako `seo`. Tagi serwerów i projektów są teraz zapisywane małymi literami, a porównanie ignoruje wielkość liter także dla danych zapisanych wcześniej.
- Zawieszona operacja Git nie blokuje już aplikacji na stałe. Gdy proces potomny (np. `ssh` na martwym połączeniu) trzymał otwarty potok po przekroczeniu limitu czasu, każda kolejna operacja wisiała aż do restartu aplikacji. Limit czasu przerywa teraz operację niezależnie od procesów potomnych, a `ssh` dostaje dodatkowo `ConnectTimeout=30`.
- Import kolekcji skilli z Git zapisuje katalog raz, a nie osobno dla każdego skilla. Wcześniej import kilkunastu skilli zużywał wszystkie sloty snapshotów odzyskiwania, a błąd w połowie importu zostawiał katalog zapisany częściowo. To samo dotyczy przejmowania wielu skilli z projektu.
- Gdy folder biblioteki jest niedostępny (odłączony dysk, brak uprawnień), aplikacja pokazuje komunikat i przycisk do Ustawień zamiast pustej biblioteki wyglądającej jak utrata danych.
- `mcp-secrets.json` od pierwszego bajtu ma uprawnienia tylko dla właściciela; wcześniej przez moment po zapisie miał uprawnienia domyślne.
- `Usuń i posprzątaj pliki` zabiera także opróżniony katalog `.skillbox/` z folderu projektu.
- Podgląd synchronizacji nie obiecuje już kopii w `.skillbox/mcp-backups` — te kopie zniknęły w 0.7.1.

## [0.7.1] - 2026-08-24

### Zmieniono

- Agentbox nie prowadzi już historii kopii zapasowych w folderach projektów. Kopia potrzebna do cofnięcia nieudanego zapisu powstaje w katalogu tymczasowym i znika po operacji, więc bezpieczeństwo transakcji zostaje bez zmian. Katalogi `.skillbox/sync-backups/` i `.skillbox/mcp-backups/` zostawione przez wcześniejsze wersje są usuwane przy najbliższej synchronizacji. W repozytorium zostają wyłącznie manifesty własności.
- Stan projektu odtwarza się przez `Usuń i posprzątaj pliki` (albo `agentbox project unsync`) i ponowną synchronizację z biblioteki. Z sekcji `Odzyskiwanie` znika lista `Backupy synchronizacji projektów`; pozostają snapshoty biblioteki i pełny backup lokalny.

### Naprawiono

- Projekt, w którym nic się nie zmieniło, nie jest już przepisywany. Wcześniej jedno `Synchronizuj wszystkie projekty` dotykało każdego projektu, nawet gdy zapisywało identyczne bajty. Taki projekt jest teraz raportowany jako `Bez zmian`.
- Decyzja o pominięciu zapisu porównuje zawartość katalogów, a nie znaczniki czasu — skill zmieniony w tej samej sekundzie co ostatnia synchronizacja nadal zostanie skopiowany.
- Pominięcie zapisu odświeża manifest, więc status projektu nie pokazuje driftu, którego nie ma.

## [0.7.0] - 2026-08-24

### Dodano

- Status każdego projektu na liście: aktualny, liczba zmian do synchronizacji, zablokowany albo brak folderu. `Sprawdź stan` w aplikacji, `agentbox project status` w terminalu.
- Edycję `SKILL.md` w aplikacji dla skilli dodanych z dysku. Zapis oznacza projekty z tym skillem jako nieaktualne. Skille z Git pozostają tylko do odczytu, bo aktualizacja zastąpiłaby zmiany.
- Przejmowanie skilli z projektu do biblioteki — katalogi ze `SKILL.md`, które blokowały synchronizację, można teraz dodać jednym kliknięciem zamiast je kasować. W terminalu `agentbox project adopt <nazwa> [--yes]`.
- Sprzątanie plików przy usuwaniu projektu: `Usuń i posprzątaj pliki` oraz `agentbox project unsync <nazwa>` usuwają wyłącznie to, co Agentbox ma w swoich manifestach.
- Wykluczenia skilli per projekt — skill wciągnięty przez tag można pominąć w jednym projekcie.
- Opcjonalne dopisywanie wygenerowanych plików MCP do `.gitignore` projektu, dla ochrony całego zespołu, a nie tylko lokalnego klona.

### Naprawiono

- Ponowny import serwera MCP nie zostawia już osieroconych sekretów w `mcp-secrets.json` ani w pełnych backupach.
- Konflikt w `config.toml` Codeksa jest wykrywany również dla `[mcp_servers."nazwa"]` w cudzysłowie; wcześniej powstawał duplikat tabeli, którego Codex nie parsował.
- Serwer MCP w Codeksie może mieć inną nazwę zmiennej po stronie serwera i hosta — Agentbox generuje `env_vars = [{ name = "...", source = "..." }]` zamiast zgłaszać błąd.
- Pojawienie się `opencode.jsonc` nie zostawia już osieroconych wpisów w `opencode.json`; stary plik jest sprzątany w tej samej transakcji.
- Usunięcie skilla lub projektu zapisuje wszystkie pliki pod jednym snapshotem i wycofuje się w całości przy błędzie. Wcześniej jedna operacja zużywała 2–3 z 10 slotów odzyskiwania.
- Backupy synchronizacji mają budżet rozmiaru, nie tylko limit dziesięciu kopii.

### Zmieniono

- Przyciski akcji przeniesione z dołu na górę każdej sekcji i ujednolicone: jedna akcja główna, reszta w tym samym stylu.
- Podgląd pokazuje w `Aktualizacje` tylko skille, które faktycznie się zmieniły, zamiast wszystkich obecnych w projekcie.
- `agentbox` ma nowe polecenia `project status`, `project adopt`, `project unsync` i `sync all`, a jego logika jest pokryta testami.

## [0.6.0] - 2026-08-24

### Dodano

- Sekcję `Globalne`: skille wybrane pojedynczo lub tagami można zsynchronizować do katalogów użytkownika (`~/.claude/skills`, `~/.codex/skills`, `~/.config/opencode/skills`). Wybór jest zapisywany, a podgląd pokazuje zmiany przed zapisem.
- Odtworzenie biblioteki ze zdalnego repozytorium Git w `Backup` oraz `agentbox restore --remote <adres>`. Projekty, lokalne ścieżki i sekrety tego Maca pozostają bez zmian, a przed zapisem powstaje pełny backup lokalny.
- `agentbox sync all` oraz `agentbox sync global` w CLI.

### Naprawiono

- Synchronizacja nie zastępuje już katalogu skilla, którego nie ma w manifeście Agentbox. Ręcznie napisany skill o tej samej nazwie zatrzymuje synchronizację zamiast zostać skasowany — ta sama zasada, która chroniła dotąd wyłącznie wpisy MCP.
- `agentbox sync project` używa tej samej ścieżki transakcyjnej co GUI, więc tworzy backup i wycofuje zmiany po błędzie.
- Git i SSH uruchamiane przez Agentbox nie mogą już czekać na hasło: pytania interaktywne są wyłączone, a każde polecenie ma limit czasu. Wcześniej prywatne repozytorium mogło zablokować aplikację na stałe.

### Zmieniono

- `Synchronizuj wszystkie projekty` pokazuje wynik dla każdego projektu osobno: zsynchronizowany, cofnięty po błędzie albo pominięty. Błąd zatrzymuje serię, zamiast pozostawiać nieznany stan.
- `agentbox sync project` synchronizuje teraz skille i MCP razem, zgodnie z zachowaniem GUI.

## [0.5.1] - 2026-08-24

### Zmieniono

- Uporządkowano listę projektów: grupy folderów są lżejsze wizualnie, zwijane i mają licznik projektów oraz akcje rozwijania wszystkich grup.
- Uproszczono import MCP przez usunięcie nieużywanego automatycznego wykrywania profili.
- Usunięto martwe API i ujednolicono bezpieczny zapis lokalnych sekretów MCP.

## [0.5.0] - 2026-08-24

### Dodano

- Grupowanie listy projektów według bezpośredniego folderu nadrzędnego.
- Podgląd i synchronizację wszystkich projektów z jednego miejsca, z walidacją całego planu przed pierwszym zapisem.

## [0.4.2] - 2026-08-24

### Zmieniono

- Skrypt publikacji GitHub Release czyści lokalne artefakty `dist/` dopiero po potwierdzonym uploadzie DMG.

### Naprawiono

- Krytyczny błąd pakowania 0.4.1, w którym CLI `agentbox` nadpisywało plik GUI `Agentbox` na systemach plików nierozróżniających wielkości liter.
- CLI jest przechowywane w osobnym katalogu `Contents/Helpers`, a build odrzuca identyczne pliki wykonywalne GUI i CLI.

## [0.4.1] - 2026-08-24

### Dodano

- Binarkę CLI do bundla aplikacji i obrazu DMG.
- Instalację polecenia `agentbox` w `/usr/local/bin` z poziomu ustawień aplikacji.
- Sprawdzanie i pobieranie wyłącznie dostępnych aktualizacji skilli Git przez `agentbox update --all`.
- Komendę `agentbox refresh`, która aktualizuje skille, tworzy backup lokalny i Git oraz synchronizuje wszystkie projekty.

### Naprawiono

- Dokumentację CLI, która wcześniej sugerowała, że polecenie jest dostępne globalnie bez instalacji.

## [0.4.0] - 2026-08-24

### Dodano

- Pełne zarządzanie klasyfikacją zmiennych i nagłówków istniejących serwerów MCP.
- Dodawanie, usuwanie i konwersję pól między zmienną systemową, sekretem lokalnym i zwykłą wartością.
- Pełne lokalne backupy w czytelnym folderze `backups/full/` wraz ze skillami, projektami, MCP i sekretami.
- Przywracanie i usuwanie pełnych backupów z interfejsu oraz rollback nieudanego przywracania.
- Kompletną instrukcję CLI z listą poleceń, opcjami i przykładami.

### Bezpieczeństwo

- Zapis konfiguracji MCP i sekretów jest jedną operacją z rollbackiem.
- Wartości istniejących sekretów pozostają zamaskowane w interfejsie.
- Folder `backups/` jest wyłączany z backupu Git, a lokalne kopie zawierające sekrety mają ograniczone uprawnienia.

## [0.3.2] - 2026-08-24

### Dodano

- Stałą informację o wersji i numerze buildu w dolnej części paska bocznego.

### Naprawiono

- Sprawdzanie aktualizacji dodaje unikalny parametr do adresu appcastu, aby nie używać nieaktualnego cache GitHub lub URLSession.

## [0.3.1] - 2026-08-24

### Dodano

- Tagi serwerów MCP i dynamiczne przypisywanie serwerów do projektów według tagów.
- Wybór dowolnej liczby pojedynczych serwerów MCP w edytorze projektu i imporcie wielu projektów.
- Listę już używanych tagów przy tagowaniu skilli i serwerów MCP.

### Zmieniono

- Presety i wymuszony wybór jednego wariantu MCP zostały zastąpione bezpośrednim wyborem serwerów oraz tagami.
- Stare przypisania presetów są odczytywane jako konkretne serwery i migrowane przy zapisie projektu.

## [0.3.0] - 2026-08-24

### Dodano

- Sekcję `Odzyskiwanie` w GUI z listą i przywracaniem snapshotów biblioteki.
- Metadane backupów synchronizacji oraz możliwość cofnięcia projektu do stanu sprzed wybranej synchronizacji.
- Automatyczną kopię aktualnego stanu przed każdą operacją przywracania.
- Testy przywracania metadanych biblioteki i plików projektu.
- Automatyczne, podpisane kryptograficznie aktualizacje aplikacji przez Sparkle i GitHub Releases.
- Ręczne sprawdzanie aktualizacji z menu aplikacji i ustawienia automatycznego pobierania.
- Dodawanie wielu projektów z podfolderów jednego katalogu ze wspólnym zestawem narzędzi, skilli, tagów i MCP.

### Zmieniono

- Budowanie DMG usuwa wcześniejsze lokalne obrazy `Agentbox-*.dmg` i `.DS_Store` z `dist/`.

## [0.2.0] - 2026-08-24

### Dodano

- Pełny podgląd synchronizacji skilli i MCP dla każdego obsługiwanego narzędzia.
- Jawny wybór klasyfikacji zmiennych i nagłówków MCP: zmienna systemowa, sekret lokalny albo zwykła wartość.
- Historię sukcesów i błędów z bieżącej sesji aplikacji.
- Rotacyjne snapshoty plików danych biblioteki w `.agentbox-snapshots/`.
- Transakcyjną synchronizację całego projektu z backupem i automatycznym rollbackiem.
- Rotacyjne backupy synchronizacji projektu w `.skillbox/sync-backups/`.
- Instrukcję użytkownika opisującą sekrety, synchronizację, odzyskiwanie danych i backup Git.
- Testy ręcznej klasyfikacji wartości MCP oraz rollbacku synchronizacji między narzędziami.

### Zmieniono

- Synchronizacja skilli i MCP jest wykonywana jako jedna operacja zamiast dwóch niezależnych zapisów.
- Manifest skilli jest aktualizowany dopiero po poprawnym wykonaniu wszystkich operacji dla danego katalogu.
- Zastępowanie katalogu skilla zachowuje poprzednią kopię do chwili udanego zapisu nowej wersji.
- Folder snapshotów biblioteki jest automatycznie wyłączany z backupu Git.

### Naprawiono

- Błędy usuwania starych skilli nie są już bezgłośnie ignorowane.
- Nieudana synchronizacja późniejszego narzędzia nie pozostawia zmian wykonanych wcześniej w tym samym projekcie.

### Bezpieczeństwo

- Klasyfikacja sekretów nie opiera się już wyłącznie na heurystyce — użytkownik zatwierdza lub zmienia typ każdego importowanego pola.
- Snapshoty biblioteki nie zawierają `mcp-secrets.json`.

## [0.1.1] - 2026-08-23

### Dodano

- Natywną aplikację macOS i CLI do zarządzania skillami oraz konfiguracjami MCP.
- Import skilli z lokalnych katalogów, repozytoriów Git i linków do folderów GitHub.
- Tagi, filtrowanie, grupowanie i sprawdzanie aktualizacji skilli.
- Projekty oraz synchronizację skilli dla Claude Code, Codex i OpenCode.
- Serwery MCP, presety, profile, import JSON i przygotowywanie konfiguracji z pomocą OpenAI lub Anthropic.
- Bezpieczne scalanie zarządzanych wpisów MCP z ręczną konfiguracją projektu.
- Lokalne kopie plików MCP przed synchronizacją.
- Lokalny i zdalny backup Git biblioteki bez sekretów i ścieżek projektów.
- Obraz instalacyjny DMG podpisany ad-hoc.

[Unreleased]: https://github.com/kacperpaluch/agentbox/compare/v0.8.1...HEAD
[0.8.1]: https://github.com/kacperpaluch/agentbox/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/kacperpaluch/agentbox/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/kacperpaluch/agentbox/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/kacperpaluch/agentbox/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/kacperpaluch/agentbox/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/kacperpaluch/agentbox/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/kacperpaluch/agentbox/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kacperpaluch/agentbox/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/kacperpaluch/agentbox/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/kacperpaluch/agentbox/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kacperpaluch/agentbox/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/kacperpaluch/agentbox/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/kacperpaluch/agentbox/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kacperpaluch/agentbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kacperpaluch/agentbox/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kacperpaluch/agentbox/releases/tag/v0.1.1
