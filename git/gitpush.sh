#!/bin/sh
echo $1
export GIT_SSH_COMMAND="ssh -i ~/.ssh/tdd_id_ed25519"
if [ -n $1 ]; then
    git add $1 -A
    git commit -m 'auto-commit $(uname -a) em $(date) '

else

    git status | grep Untracked
    read -n 1 -p 'Commit?' answer
    case "${answer,,}" in
    s/y)
        git commit -m 'auto-commit $(uname -a) em $(date) '
        ;;
    esac
fi

# git push -u origin main git@github.com:thedandare/ubunix.git
git push --set-upstream git@github.com:thedandare/ubunix.git main

