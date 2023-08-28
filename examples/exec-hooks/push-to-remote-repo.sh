#!/usr/bin/env bash

set -euo pipefail

# Using a git repository
echo "Running with:
- PNAME=$PNAME
- PVERSION=$PVERSION
- PFILE=$PFILE
- PURL=$PURL
- PURL_OFFICIAL=$PURL_OFFICIAL
"
cat << EOF
WOULD NOW RUN:
cd my-local-repo
mkdir -p "plugins/$PNAME/$PVERSION/"
cp "$PFILE" "plugins/$PNAME/$PVERSION/"
git add "plugins/$PNAME/$PVERSION/"
git commit -m "Add plugin $PNAME:$PVERSION"
git push
EOF