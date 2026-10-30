#!/usr/bin/env python3
"""Render the Lumenaire panel and bar offscreen from synthetic fixtures.

Every state in tests/fixtures/*.json (except themes.json) is drawn at 468 and
360 px on a light and a dark Omarchy palette, plus one bar-states strip per
palette, into .impeccable/review/*.png. Nothing touches the desktop, the
daemon or pc-lights: the views bind to tests/FakeService.qml. Corners follow
Hyprland's rounding, as the shell's do; LUMENAIRE_RADIUS sets it instead.

  python tests/render.py                      # everything
  LUMENAIRE_ONLY=normal,failed python tests/render.py
  LUMENAIRE_RADIUS=10 python tests/render.py  # a rounded theme
  LUMENAIRE_CAPTURE_DIR=/tmp/x python tests/render.py

A fixture may build on another ("base") and patch the frozen engine views it
names (RFC 6902): statusPatch, editorFile/editorPatch, previewFile/
previewPatch, and for the screen editor screensFile/screensPatch (theme
screens --json), mediaListFile/mediaListPatch (media list --json),
frameFile/framePatch (media frame --json) and jobs ([{"file", "patch"}] of
media.job.*.json records). ui.page "screen" with ui.screen = {role, step,
tab, query, cursor, keys, crop, …} opens a screen's page. Pictures in them
are relative to tests/fixtures (tests/ui/thumbs/ holds the screen fixtures').
The wallpaper (desktop --json) comes as desktopFile/desktopPatch (the page's
theme) and desktopCurrentFile/desktopCurrentPatch (the theme the desktop
follows, when the page shows another); ui.page "wallpaper" with
ui.wallpaper = {theme, cursor, keys} opens its page.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
fixtures = project / 'tests/fixtures'
captures = Path(os.environ.get('LUMENAIRE_CAPTURE_DIR') or project / '.impeccable/review')
captures.mkdir(parents=True, exist_ok=True)
themes_dir = Path.home() / '.config/omarchy/themes'
stock_dir = Path('/usr/share/omarchy/themes')


def palette(name):
    for base in (themes_dir, stock_dir):
        if (base / name / 'colors.toml').is_file():
            shell = base / name / 'shell.toml'
            return {'name': name, 'colors': (base / name / 'colors.toml').read_text(),
                    'shell': shell.read_text() if shell.is_file() else ''}
    raise SystemExit(f'palette {name} not found')


def rounding():
    try:
        out = subprocess.run(['hyprctl', 'getoption', 'decoration:rounding'], capture_output=True, text=True, timeout=2).stdout
        return int(out.split('int:')[1].split()[0])
    except Exception:
        return 0


only = [s for s in os.environ.get('LUMENAIRE_ONLY', '').split(',') if s]
# Panel states are every fixture object except the theme lists (arrays) and
# the engine contract files (profile.*, eff.*, and the frozen editor.*,
# preview.*, screens.*, media.* and desktop.* views the fixtures build on).
def is_state(p):
    if p.stem.split('.')[0] in ('profile', 'eff', 'editor', 'preview', 'screens', 'media', 'desktop') and '.' in p.stem:
        return False
    return isinstance(json.loads(p.read_text()), dict)


def unescape(token):
    return token.replace('~1', '/').replace('~0', '~')


def patch(doc, ops):
    """RFC 6902 add/replace/remove on a copy of doc (the engine's subset)."""
    doc = json.loads(json.dumps(doc))
    for op in ops or []:
        tokens = [unescape(t) for t in op['path'].lstrip('/').split('/')] if op['path'] else []
        cur = doc
        for t in tokens[:-1]:
            cur = cur[int(t)] if isinstance(cur, list) else cur.setdefault(t, {})
        last = tokens[-1]
        if op['op'] == 'remove':
            if isinstance(cur, list):
                cur.pop(int(last))
            else:
                cur.pop(last, None)
        elif isinstance(cur, list):
            if last == '-':
                cur.append(op['value'])
            elif op['op'] == 'add':
                cur.insert(int(last), op['value'])
            else:
                cur[int(last)] = op['value']
        else:
            cur[last] = op['value']
    return doc


def fixture(name):
    raw = json.loads((fixtures / f'{name}.json').read_text())
    data = raw
    # An editor fixture builds on another state ("base"); status, service and
    # sensors merge key by key, anything else it names replaces the base's.
    if raw.get('base'):
        base = fixture(raw['base'])['data']
        data = dict(base)
        for key, value in raw.items():
            if key in ('status', 'service', 'sensors') and isinstance(value, dict) and isinstance(base.get(key), dict):
                data[key] = {**base[key], **value}
            else:
                data[key] = value
        data.pop('base', None)
    # Patches (RFC 6902) from this file, on top of whatever the base built.
    if raw.get('statusPatch'):
        data['status'] = patch(data.get('status') or {}, raw['statusPatch'])
    # A fixture with its own theme list (v1.1 coverage, example themes).
    if raw.get('themesFile'):
        data['themeList'] = json.loads((fixtures / raw['themesFile']).read_text())
    # v1.2 theme fields (draft, editable, edit_block) on top of the list.
    if raw.get('themeEdits'):
        themes = data.get('themeList') or json.loads((fixtures / 'themes.json').read_text())
        data['themeList'] = [{**t, **raw['themeEdits'].get('*', {}), **raw['themeEdits'].get(t['name'], {})} for t in themes]
    # The frozen engine views (editor.sakura.json, preview.live.json, for
    # the screen editor screens.sakura.json, media.list.*.json,
    # media.frame.json, and the wallpaper's desktop.*.json), patched.
    for key in ('editor', 'preview', 'screens', 'mediaList', 'frame', 'desktop', 'desktopCurrent'):
        if raw.get(key + 'File'):
            data[key] = patch(json.loads((fixtures / raw[key + 'File']).read_text()), raw.get(key + 'Patch'))
        elif raw.get(key + 'Patch'):
            data[key] = patch(data.get(key) or {}, raw[key + 'Patch'])
    # Media jobs (media.job.*.json records): [{"file", "patch"}] or records.
    if raw.get('jobs') is not None:
        data['jobs'] = [patch(json.loads((fixtures / j['file']).read_text()), j.get('patch')) if isinstance(j, dict) and j.get('file') else j
                        for j in raw['jobs']]
    return {'name': name, 'data': data}


states = sorted(p.stem for p in fixtures.glob('*.json') if is_state(p))
if only:
    states = [s for s in states if s in only]
palettes = [palette(n) for n in os.environ.get('LUMENAIRE_PALETTES', 'glass-white,sakura').split(',')]
plan = {
    'palettes': palettes,
    'widths': [468, 360],
    'radius': int(os.environ.get('LUMENAIRE_RADIUS', rounding())),
    'fixturesDir': str(fixtures),
    'themes': json.loads((fixtures / 'themes.json').read_text()),
    'fixtures': [fixture(s) for s in states],
    'captureDir': str(captures),
}

with tempfile.TemporaryDirectory(prefix='lumenaire-render-') as directory:
    root = Path(directory)
    for name in ('Ui', 'Commons'):
        (root / name).symlink_to('/usr/share/omarchy/shell/' + name)
    for name in ('Lights', 'runtime', 'config', 'cache'):
        (root / name).mkdir(mode=0o700)
    for source in list(project.glob('*.qml')) + list(project.glob('*.js')) + [project / 'tests/FakeService.qml']:
        shutil.copy2(source, root / 'Lights' / source.name)
    shutil.copy2(project / 'tests/render.qml', root / 'shell.qml')
    (root / 'plan.json').write_text(json.dumps(plan))
    env = os.environ | dict(XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                            XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen',
                            QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software', LIBGL_ALWAYS_SOFTWARE='1',
                            LUMENAIRE_PLAN=str(root / 'plan.json'))
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE'):
        env.pop(key, None)
    try:
        result = subprocess.run(['quickshell', '-p', str(root), '--no-color'], env=env,
                                capture_output=True, text=True, timeout=int(os.environ.get('LUMENAIRE_TIMEOUT', 900)))
        log = result.stdout + result.stderr
    except subprocess.TimeoutExpired as timeout:
        log = (timeout.stdout or b'').decode() + (timeout.stderr or b'').decode()
        (project / 'tests/render-result.log').write_text(log)
        raise SystemExit('render timed out; see tests/render-result.log\n' + log[-3000:])
    (project / 'tests/render-result.log').write_text(log)
    # Layer-shell windows cannot load offscreen; the live install covers them.
    allowed = ('Unable to find hyprland socket', 'Type Ui.KeyboardPanel unavailable', 'No PanelWindow backend loaded',
               'Panel.qml', 'panel failed to load')
    unexpected = [line for line in log.splitlines()
                  if ('ERROR' in line or 'WARN scene' in line or 'TypeError' in line or 'ReferenceError' in line)
                  and not any(a in line for a in allowed)]
    assert not unexpected, '\n'.join(unexpected)
    assert result.returncode == 0 and 'LUMENAIRE_UI_CAPTURE_OK' in log, log[-4000:]
    shots = sorted(p.name for p in captures.glob('*.png'))
    print(f'Captured {len(states)} states x {len(palettes)} palettes x 2 widths + bar strips into {captures}')
