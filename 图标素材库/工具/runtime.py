"""Resolve tools without depending on one user's PATH."""
import os, shutil
from pathlib import Path
BUNDLE = Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node'
def node():
    candidate = os.environ.get('RIVER_ICON_NODE') or shutil.which('node')
    if not candidate and (BUNDLE/'bin/node').exists(): candidate = str(BUNDLE/'bin/node')
    if not candidate: raise RuntimeError('Node.js is required; set RIVER_ICON_NODE')
    return candidate
def node_env():
    return dict(os.environ, NODE_PATH=os.environ.get('RIVER_ICON_NODE_MODULES', str(BUNDLE/'node_modules')))
