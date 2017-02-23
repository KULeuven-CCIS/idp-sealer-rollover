#!/bin/bash -e
set -xv
APP=idp-sealer-rollover
DEPS="YAML::Tiny App::FatPacker"

# Create a fatcked standaline executable
# You should be in the bin directory of the distribution
if [ ! -z `which cpan` ]; then
    cpanm $DEPS
    else cpan $DEPS
fi
fatpack pack ../src/$APP.pl > ../$APP
rm -rf fatlib
chmod +x ../$APP

echo "Executable created."
