# Changelog

Wszystkie istotne zmiany w Agentbox są dokumentowane w tym pliku.

Format jest oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/). Projekt używa wersjonowania semantycznego od pierwszego stabilnego wydania.

## [Unreleased]

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

[Unreleased]: https://github.com/kacperpaluch/agentbox/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/kacperpaluch/agentbox/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/kacperpaluch/agentbox/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/kacperpaluch/agentbox/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kacperpaluch/agentbox/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/kacperpaluch/agentbox/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/kacperpaluch/agentbox/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kacperpaluch/agentbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kacperpaluch/agentbox/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kacperpaluch/agentbox/releases/tag/v0.1.1
