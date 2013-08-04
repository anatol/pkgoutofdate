#!/usr/bin/bash

shopt -u extglob

if ! source $1; then
  failed to source $1
  exit 1
fi
shopt -s extglob

echo $pkgname
echo $pkgver

for file in "${source[@]}"; do
  echo $file
done
