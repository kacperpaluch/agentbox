# Changelog

Wszystkie istotne zmiany w Agentbox są dokumentowane w tym pliku.

Format jest oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/). Projekt używa wersjonowania semantycznego od pierwszego stabilnego wydania.

## [Unreleased]

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

[Unreleased]: https://github.com/kacperpaluch/agentbox/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/kacperpaluch/agentbox/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kacperpaluch/agentbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kacperpaluch/agentbox/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kacperpaluch/agentbox/releases/tag/v0.1.1
