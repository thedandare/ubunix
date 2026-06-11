#!/bin/sh
echo $1
if [ -n $1 ]; then
    git add $1 -A
else
    git status | grep Untracked
fi
git commit -m 'auto-commit $(uname -a) em $(date) '
git push git@github.com:thedandare/ubunix.git
