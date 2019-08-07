#!/usr/local/bin/python3
from __future__ import print_function
from pyfiglet import Figlet
from clint.arguments import Args
from clint.textui import puts, colored, indent

import sys
import os

sys.path.insert(0, os.path.abspath('..'))

f = Figlet(font='slant')
print(f.renderText('Pivotal Platform Setup'))

args = Args()

with indent(4):
    puts(colored.blue('Aruments passed in: ') + str(args.all))
    puts(colored.blue('Flags detected: ') + str(args.flags))
    puts(colored.blue('Files detected: ') + str(args.files))
    puts(colored.blue('NOT Files detected: ') + str(args.not_files))
    puts(colored.blue('Grouped Arguments: ') + str(dict(args.grouped)))
