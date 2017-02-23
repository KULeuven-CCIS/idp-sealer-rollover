#!/bin/bash -e
set -xv
# Create a fatcked standaline executable
# You should be in the bin directory of the distribution
if [ ! -z `which cpan` ]; then
    cpanm YAML::Tiny
    else cpan YAML::Tiny
fi
APP=../idp-sealer-rollover
fatpack trace ../src/idp-sealer-rollover.pl
fatpack packlists-for `cat fatpacker.trace` >packlists
fatpack tree `cat packlists`
fatpack file idp-sealer-rollover.pl > $APP
chmod +x $APP
rm -rf fatpacker.trace packlists fatlib

echo "Executable created."
