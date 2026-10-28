#!/bin/zsh
# Compile iBaobab et produit build/iBaobab.app (mêmes variables facultatives que build.sh).
PRODUCT=iBaobab exec "${0:A:h}/build.sh" "$@"
