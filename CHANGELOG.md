# Changelog

Wszystkie istotne zmiany w Agentbox są dokumentowane w tym pliku.

Format jest oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/). Projekt używa wersjonowania semantycznego od pierwszego stabilnego wydania.

## [Unreleased]

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
