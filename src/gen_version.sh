#!/bin/bash

VERSION=$(git describe --always --tags --dirty=+M)
cat > version.ml <<- EOF
(* do not edit; generated by gen_version.sh *)

let current = "$VERSION"
EOF