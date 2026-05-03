#!/usr/bin/env python3
"""
Подрезка блока <claude-mem-context>...</claude-mem-context> в CLAUDE.md.

Логика:
- Оставляет записи не старше N дней (--days, default 7).
- На каждый оставшийся день — топ-M записей по колонке Read (--max-per-day, default 5).
- Идемпотентно: при повторном запуске на уже подрезанном файле пишет NO-CHANGE.
- Atomic write: tmp + rename, бекап в ~/.claude/state/mem-backup-<ISO>-<file>.
- Хранит последние 7 бекапов.
- Ошибки парсинга → лог в ~/.claude/state/prune-errors.log, файл НЕ переписывается.

Usage:
    python3 prune-mem.py <path> [--days 7] [--max-per-day 5] [--dry-run] [--today YYYY-MM-DD]
"""
import argparse
import datetime
import re
import shutil
import sys
from pathlib import Path

START_MARKER = '<claude-mem-context>'
END_MARKER = '</claude-mem-context>'
# Заголовки секций вида "### Feb 7, 2026"
DATE_HEADER_RE = re.compile(r'^###\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})\s*$', re.M)
# Read-колонка: "~399" или "399"
READ_COL_RE = re.compile(r'~?(\d+)\s*$')

HOME = Path.home()
STATE_DIR = HOME / '.claude' / 'state'
ERR_LOG = STATE_DIR / 'prune-errors.log'


def log_err(msg, path):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with ERR_LOG.open('a') as f:
        ts = datetime.datetime.now().isoformat(timespec='seconds')
        f.write(f'{ts}\t{path}\t{msg}\n')


def parse_date(s):
    try:
        return datetime.datetime.strptime(s.strip(), '%b %d, %Y').date()
    except ValueError:
        return None


def cap_table_rows(section, max_per_day):
    """Найти первую markdown-таблицу в секции, оставить header + separator + top-M строк по Read."""
    lines = section.split('\n')
    header_idx = None
    for i in range(len(lines) - 1):
        line = lines[i]
        nxt = lines[i + 1]
        if line.startswith('|') and line.endswith('|') and '----' in nxt:
            header_idx = i
            break
    if header_idx is None:
        return section
    sep_idx = header_idx + 1
    data_start = sep_idx + 1
    data_end = data_start
    while data_end < len(lines) and lines[data_end].startswith('|') and lines[data_end].endswith('|'):
        data_end += 1
    data_rows = lines[data_start:data_end]
    if len(data_rows) <= max_per_day:
        return section

    def read_count(row):
        cells = [c.strip() for c in row.strip('|').split('|')]
        if not cells:
            return 0
        m = READ_COL_RE.search(cells[-1])
        return int(m.group(1)) if m else 0

    kept = sorted(data_rows, key=read_count, reverse=True)[:max_per_day]
    return '\n'.join(lines[:data_start] + kept + lines[data_end:])


def prune_block(content, days, max_per_day, today):
    matches = list(DATE_HEADER_RE.finditer(content))
    if not matches:
        return content  # нет дат-секций → не трогаем
    prefix = content[:matches[0].start()]
    cutoff = today - datetime.timedelta(days=days)
    kept_sections = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
        section = content[start:end]
        first_nl = section.find('\n')
        if first_nl == -1:
            continue
        header_line = section[:first_nl]
        section_body = section[first_nl + 1:]
        date_match = DATE_HEADER_RE.match(header_line)
        if not date_match:
            continue
        d = parse_date(date_match.group(1))
        if d is None or d < cutoff:
            continue
        capped = cap_table_rows(section_body, max_per_day)
        kept_sections.append(header_line + '\n' + capped)
    if not kept_sections:
        # Все секции старше cutoff — оставить только статический префикс
        return prefix.rstrip() + '\n'
    return prefix + ''.join(kept_sections)


def backup_file(path):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now().strftime('%Y-%m-%dT%H-%M-%S')
    # Уникальное имя по полному пути (без лидирующего /), чтобы не было коллизий
    # между двумя файлами с одинаковым basename из разных каталогов.
    safe_path = str(path.resolve()).lstrip('/').replace('/', '_')
    dest = STATE_DIR / f'mem-backup-{ts}-{safe_path}'
    shutil.copy2(path, dest)
    backups = sorted(STATE_DIR.glob('mem-backup-*'))
    for old in backups[:-7]:
        try:
            old.unlink()
        except OSError:
            pass
    return dest


def process(path, days, max_per_day, dry_run, today):
    if not path.exists():
        log_err('file not found', path)
        print(f'ERROR: {path} not found', file=sys.stderr)
        return False
    text = path.read_text()
    start = text.find(START_MARKER)
    if start == -1:
        print(f'SKIP: no <claude-mem-context> in {path}')
        return True
    end = text.find(END_MARKER, start + len(START_MARKER))
    if end == -1:
        log_err('start marker found but no end marker', path)
        print(f'ERROR: {path} has start marker but no end marker', file=sys.stderr)
        return False
    block_start = start + len(START_MARKER)
    block_content = text[block_start:end]
    new_block = prune_block(block_content, days, max_per_day, today)
    new_text = text[:start] + START_MARKER + new_block + text[end:]
    if new_text == text:
        print(f'NO-CHANGE: {path} (already clean)')
        return True
    if dry_run:
        print(f'DRY-RUN: {path} ({len(text)} -> {len(new_text)} bytes)')
        return True
    backup_file(path)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(new_text)
    tmp.replace(path)
    print(f'PRUNED: {path} ({len(text)} -> {len(new_text)} bytes)')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--max-per-day', type=int, default=5)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--today', default=None, help='YYYY-MM-DD (для тестов)')
    args = ap.parse_args()
    today = (datetime.datetime.strptime(args.today, '%Y-%m-%d').date()
             if args.today else datetime.date.today())
    ok = process(Path(args.path), args.days, args.max_per_day, args.dry_run, today)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
