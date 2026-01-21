# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

strava-gear is a rule-based tracker of gear and component wear for Strava. It reads activities from a local strava-offline database (or CSV) and applies YAML-defined rules to compute component usage (distance, time, elevation gain).

## Common Commands

```bash
make                    # Setup .venv/ and install dependencies
make check              # Run all checks (lints + tests + readme validation)
make lint               # Run flake8, mypy, isort
make test               # Run pytest and prysk tests
make test-pytest        # Run pytest tests only
make test-prysk         # Run prysk (cram-like) tests only
```

Run a single pytest test:
```bash
.venv/bin/python -m pytest tests/test_data.py::test_name -v
```

Run a single prysk test:
```bash
PATH=".venv/bin:$PATH" .venv/bin/python -m prysk tests/csv.md
```

## Architecture

### Data Flow
1. **Input**: Activities loaded from strava-offline SQLite database or CSV (`src/strava_gear/input/activities.py`)
2. **Rules**: YAML configuration parsed and validated (`src/strava_gear/input/rules.py`)
3. **Core**: Rules applied to activities to compute component usage (`src/strava_gear/core.py`)
4. **Output**: Reports generated via tabulate (`src/strava_gear/report.py`)

### Key Types (src/strava_gear/data.py)
- `Rule`: Component assignments for bikes/hashtags at a point in time
- `Rules`: Collection of rules + components + bike aliases
- `Component`: Gear component with accumulated usage stats
- `Usage`: Aggregated distance/time/elevation for components

### Entry Points
- `strava-gear` CLI → `src/strava_gear/cli.py`
- `strava-gear-sync` CLI → `src/strava_gear/cli_strava_offline.py` (thin wrapper around strava-offline)

### Rules Processing
Rules are sorted by `since` date and accumulated using `itertools.accumulate`. The `merge_asof` function matches each activity to its effective rule set. Components can be assigned to bikes or hashtags (for temporary changes like race wheels).

## Code Style

- isort profile: `open_stack`
- Line length: 120 (ruff config)
- Type hints throughout with mypy strict checking
- Tests: pytest for unit tests, prysk for CLI integration tests (markdown files with shell commands)
