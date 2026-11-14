# SPDX-License-Identifier: GPL-3.0-only

import argparse
from collections.abc import Iterable
import logging
from pathlib import Path, PurePosixPath
import re
import shutil
from typing import override

from lib.filesystem import CpioFs, ExtFs
from lib.modules import MissingArgs, Module, ModuleRequirements


logger = logging.getLogger(__name__)


class PreinstallModule(Module):
    APP_DIR: PurePosixPath = PurePosixPath('/system/app')
    OVERLAY_DIR: PurePosixPath = PurePosixPath('/overlay')

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--preinstall-app',
            action='append',
            metavar='NAME=APK',
            help='APK to add to the system image as /system/app/NAME/NAME.apk',
        )
        parser.add_argument(
            '--preinstall-overlay',
            action='append',
            type=Path,
            metavar='APK',
            help='Static resource overlay to add to /product/overlay',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        specs: list[str] = args.preinstall_app or []
        self.overlays: list[Path] = args.preinstall_overlay or []

        if not specs and not self.overlays:
            raise MissingArgs()

        self.apps: dict[str, Path] = {}
        for spec in specs:
            name, sep, apk = spec.partition('=')
            if not sep or not re.fullmatch(r'[A-Za-z0-9]+', name):
                raise ValueError(f'Bad --preinstall-app value: {spec!r}')
            if name in self.apps:
                raise ValueError(f'Duplicate preinstalled app: {name}')
            self.apps[name] = Path(apk)

    @override
    def requirements(self) -> ModuleRequirements:
        images: set[str] = set()
        if self.apps:
            images.add('system')
        if self.overlays:
            images.add('product')

        return ModuleRequirements(
            boot_images=set(),
            ext_images=images,
            selinux_patching=False,
        )

    @override
    def inject(
        self,
        boot_fs: dict[str, CpioFs],
        ext_fs: dict[str, ExtFs],
        sepolicies: Iterable[Path],
    ) -> None:
        for name, apk in self.apps.items():
            dest = self.APP_DIR / name / f'{name}.apk'
            logger.info(f'Preinstalling app: {apk} -> system:{dest}')

            system_fs = ext_fs['system']
            # No exist_ok: a name GrapheneOS already uses must fail the build
            # rather than replace one of its apps.
            system_fs.mkdir(dest.parent)
            self._copy(apk, system_fs, dest)

        for apk in self.overlays:
            dest = self.OVERLAY_DIR / apk.name
            logger.info(f'Preinstalling overlay: {apk} -> product:{dest}')

            self._add_overlay(apk, ext_fs['product'], dest)

    @staticmethod
    def _copy(apk: Path, fs: ExtFs, dest: PurePosixPath):
        with open(apk, 'rb') as f_in, fs.open(dest, 'xb', mode=0o644) as f_out:
            shutil.copyfileobj(f_in, f_out)

    def _add_overlay(self, apk: Path, fs: ExtFs, dest: PurePosixPath):
        # file_contexts describes paths as seen from the system root, so it
        # has no match for a path relative to the product image. Take the
        # label from an overlay GrapheneOS already ships in the same folder.
        siblings = [
            e for e in fs.info.entries
            if e.path.parent == dest.parent
            and e.file_type == 'RegularFile'
            and e.path.suffix == '.apk'
        ]
        if not siblings:
            raise RuntimeError(f'No existing overlays in product:{dest.parent}')

        contexts = fs.contexts
        fs.contexts = [(re.compile(r'.*'), 'placeholder')]
        try:
            self._copy(apk, fs, dest)
        finally:
            fs.contexts = contexts

        entry = next(e for e in fs.info.entries if e.path == dest)
        entry.xattrs['security.selinux'] = siblings[0].xattrs['security.selinux']
