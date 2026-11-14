#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0-only

# Runs my-avbroot-setup's patch.py with PreinstallModule added to its module
# list, which upstream hard-codes.

import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(os.environ.get('MY_AVBROOT_SETUP', '.tmp/my-avbroot-setup')).resolve()))

from lib import modules  # noqa: E402
import patch  # noqa: E402
from preinstall_module import PreinstallModule  # noqa: E402

upstream_modules = modules.all_modules
modules.all_modules = lambda: [*upstream_modules(), PreinstallModule]

patch.main()
