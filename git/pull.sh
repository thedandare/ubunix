#!/bin/bash
# echo $1
export GIT_SSH_COMMAND="ssh -i ~/.ssh/tdd_id_ed25519"
git pull
# export Fg=\033[0;
# export Fb=\033[1;
# export R=31m
# export G=32m
# export B=34m
# echo -e "$Fb$G tes $Fb$B te "
#
# if [ -n $1 ]; then
#     echo -e  "\[0;31m parama 1:$1"
#     git add $1 -A
#     git commit -m 'auto-commit $(uname -a) em $(date) '
#
# else
#     echo -e "[0;31m git add não executado"
#
#     git status | grep Untracked
#     read -n 1 -p "Commit?" answer
#     case "${answer,,}" in
#     s/y)
#         git commit -m 'auto-commit $(uname -a) em $(date) '
#         ;;
#     esac
# fi
#
# read -n 1 -p "Push" answer
# case "${answer,,}" in
#     s/y)
#         git push --set-upstream git@github.com:thedandare/ubunix.git main
#     ;;
# esac
#
#
# # git push -u origin main git@github.com:thedandare/ubunix.git
#
