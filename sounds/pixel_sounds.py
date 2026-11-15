#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0-only

"""Collects the Pixel sound packs for a phone that does not run Google's system.

Google's Sounds app lists its packs in XML resources, one per pack and kind, each track with a title and an
address on gstatic.com. A stock Pixel image only carries the "Pixel Sounds" pack; the app downloads the rest
when a sound is picked.

  catalogue  reads the track list out of the Sounds app's APK (needs aapt2)
  fetch      downloads every track once
  collect    writes the set for the phone: Ringtones, Alarms and Notifications, every file named after its
             pack and title (needs vorbiscomment)

None of the sounds belong in this repository. They are Google's, and stay on the machine that fetched them.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

KINDS = {'alarm': 'alarms', 'notif': 'notifications', 'ring': 'ringtones'}
FOLDERS = {'alarms': 'Alarms', 'notifications': 'Notifications', 'ringtones': 'Ringtones'}
# The app names its resources after working titles, and lists "Pixel Sounds" once per phone generation
PACKS = {
    'classical': 'Classical Harmonies',
    'gems': 'Gems',
    'loud': 'Play It Loud',
    'material_adventures': 'Material Adventures',
    'minimal': 'Minimal Melodies',
    'natural_elements': 'Natural Elements',
    'pixel_gen1': 'Pixel Sounds',
    'pixel_gen2': 'Pixel Sounds',
    'real_world': 'Reality Bytes',
    'retro': 'Retro Riffs',
    'seasonal': 'Seasonal Celebrations',
    'sound_matters': 'Sound Matters',
}


def catalogue(apk, out):
    dump = subprocess.run(['aapt2', 'dump', 'resources', apk], capture_output=True, text=True, check=True).stdout
    lines = dump.splitlines()
    strings = {}
    named = {}
    aliases = {}
    lists = {}
    for i, line in enumerate(lines[:-1]):
        m = re.match(r'\s+resource (0x[0-9a-f]+) (string|xml)/(\S+)', line)
        if not m:
            continue
        number, kind, name = m.groups()
        if kind == 'string':
            value = re.match(r'\s+\(\) "(.*)"$', lines[i + 1])
            alias = re.match(r'\s+\(\) @string/(\S+)$', lines[i + 1])
            if value:
                strings[int(number, 16)] = named[name] = value.group(1)
            elif alias:
                # One title is defined as "the same as that other string"
                aliases[int(number, 16)] = alias.group(1)
        else:
            path = re.match(r'\s+\(\) \(file\) (\S+) type=XML', lines[i + 1])
            if path and name.split('_', 1)[0] in KINDS:
                lists[name] = path.group(1)

    for number, target in aliases.items():
        if target in named:
            strings[number] = named[target]

    tracks = []
    for name, path in sorted(lists.items()):
        prefix, pack = name.split('_', 1)
        tree = subprocess.run(['aapt2', 'dump', 'xmltree', '--file', path, apk],
                              capture_output=True, text=True, check=True).stdout
        track = None
        for line in tree.splitlines():
            line = line.strip()
            if line.startswith('E: track'):
                track = {'kind': KINDS[prefix], 'pack': pack}
                tracks.append(track)
                continue
            m = re.match(r'A: \S+:(\w+)\(0x[0-9a-f]+\)=(.*)$', line)
            if track is None or not m:
                continue
            key, value = m.groups()
            reference = re.match(r'@(0x[0-9a-f]+)$', value)
            quoted = re.match(r'"(.*?)" \(Raw:', value)
            if reference:
                value = strings.get(int(reference.group(1), 16), value)
            elif quoted:
                value = quoted.group(1)
            track[key] = value

    unknown = sorted({t['pack'] for t in tracks} - set(PACKS))
    if unknown:
        sys.exit(f'error: the app has packs this script has no name for: {", ".join(unknown)}')
    untitled = [t['url'] for t in tracks if t.get('title', '@').startswith('@')]
    if untitled:
        sys.exit(f'error: no title found for {", ".join(untitled)}')
    with open(out, 'w') as f:
        json.dump(tracks, f, indent=1)
    print(f'result: {len(tracks)} tracks in {len(lists)} lists written to {out}')


def local_path(url):
    # Most tracks sit under /pixel/sounds/, newer ones under /pixel/sounds_v2/
    path = urllib.parse.urlparse(url).path
    return path.removeprefix('/pixel/sounds/').removeprefix('/pixel/').lstrip('/')


def fetch(catalogue_file, dest):
    urls = sorted({t['url'] for t in json.load(open(catalogue_file))})
    print(f'start: {len(urls)} files to fetch', flush=True)
    fetched = present = failed = 0
    for url in urls:
        path = os.path.join(dest, local_path(url))
        if os.path.exists(path) and os.path.getsize(path) > 0:
            present += 1
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        error = None
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'User-Agent': 'curl/8'})
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = response.read()
                if not data.startswith(b'OggS'):
                    raise ValueError('not an Ogg file')
                with open(path + '.part', 'wb') as f:
                    f.write(data)
                os.replace(path + '.part', path)
                error = None
                break
            except (urllib.error.URLError, ValueError, TimeoutError) as e:
                error = e
                time.sleep(2)
        if error:
            failed += 1
            print(f'error: {url}: {error}', flush=True)
        else:
            fetched += 1
        # One request at a time with a pause: this is somebody else's server
        time.sleep(0.25)
    print(f'result: fetched {fetched}, already present {present}, failed {failed}')
    return 1 if failed else 0


def retitle(source, dest, title):
    # Google's files name their title as a string inside the Sounds app, which a phone without that app lists
    # as the reference itself. Only the comment header is rewritten; the sound is copied as it is, with any
    # haptic channel Google gave it.
    listed = subprocess.run(['vorbiscomment', '-l', '-R', source], capture_output=True, text=True, check=True)
    comments = [c for c in listed.stdout.splitlines() if c and not c.upper().startswith('TITLE=')]
    comments.append(f'TITLE={title}')
    subprocess.run(['vorbiscomment', '-w', '-R', source, dest + '.part'], input='\n'.join(comments) + '\n',
                   capture_output=True, text=True, check=True)
    os.replace(dest + '.part', dest)


def collect(catalogue_file, packs, image_audio, out):
    work = {}
    for track in json.load(open(catalogue_file)):
        pack = PACKS[track['pack']]
        title = f'{pack}: {track["title"]}'
        name = re.sub(r'[^A-Za-z0-9 \'&,.()!-]', '_', f'{pack} - {track["title"]}') + '.ogg'
        dest = os.path.join(out, FOLDERS[track['kind']], name)
        source = os.path.join(packs, local_path(track['url']))
        if 'systemId' in track:
            # The copy in the phone image is the one a Pixel plays
            in_image = os.path.join(image_audio, track['kind'], track['systemId'])
            if os.path.isfile(in_image):
                source = in_image
        if dest in work and work[dest] != (source, title):
            sys.exit(f'error: two different tracks would both become {dest}')
        work[dest] = (source, title)

    for folder in FOLDERS.values():
        os.makedirs(os.path.join(out, folder), exist_ok=True)
    print(f'start: {len(work)} sounds', flush=True)
    failed = 0
    for dest, (source, title) in work.items():
        try:
            retitle(source, dest, title)
        except subprocess.CalledProcessError as e:
            failed += 1
            print(f'error: {dest}: {e.stderr.strip()}', flush=True)
        except OSError as e:
            failed += 1
            print(f'error: {dest}: {e}', flush=True)

    # A sound the app no longer lists must not linger here, or it would stay on the phone as well
    for folder in FOLDERS.values():
        for name in os.listdir(os.path.join(out, folder)):
            path = os.path.join(out, folder, name)
            if path not in work:
                os.remove(path)
    print(f'result: {len(work) - failed} sounds collected in {out}, {failed} failed')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    c = sub.add_parser('catalogue', help='read the track list out of the Sounds app')
    c.add_argument('apk', help='SoundPickerPrebuilt.apk from /product/app of a stock Pixel image')
    c.add_argument('out', help='catalogue file to write')
    f = sub.add_parser('fetch', help='download every track in the catalogue')
    f.add_argument('catalogue')
    f.add_argument('dest')
    b = sub.add_parser('collect', help='write the set for the phone')
    b.add_argument('catalogue')
    b.add_argument('packs', help='folder the fetch step filled')
    b.add_argument('image_audio', help='/product/media/audio of a stock Pixel image')
    b.add_argument('out')
    args = parser.parse_args()
    if args.command == 'catalogue':
        catalogue(args.apk, args.out)
    elif args.command == 'fetch':
        sys.exit(fetch(args.catalogue, args.dest))
    else:
        sys.exit(collect(args.catalogue, args.packs, args.image_audio, args.out))


if __name__ == '__main__':
    main()
