#!/usr/bin/env python3
"""Check generated feed bounds and immutable archive metadata before publication."""
import base64
import sys
from pathlib import Path
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
feed, archive, build = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
assert feed.stat().st_size <= 1 << 20, 'Feed exceeds 1 MiB'
assert 0 < archive.stat().st_size <= 4 << 30, 'Archive exceeds 4 GiB'
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root = ET.fromstring(feed.read_bytes())
items = root.findall('./channel/item')
assert len(items) == 1, 'Stable release feed must contain exactly one full update'
item = items[0]
enclosure = item.find('enclosure')
assert enclosure is not None
assert (item.findtext(ns+'version') or enclosure.get(ns+'version')) == build
assert int(enclosure.get('length','0')) == archive.stat().st_size
assert len(base64.b64decode(enclosure.get(ns+'edSignature',''), validate=True)) == 64
url = urlsplit(enclosure.get('url',''))
assert url.scheme == 'https' and url.hostname == 'github.com' and '/releases/download/v' in url.path
assert url.path.endswith('/'+archive.name) and not url.query and not url.fragment
print('Feed size, archive size, version, signature encoding and immutable URL verified.')
