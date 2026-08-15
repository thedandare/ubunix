#!/bin/sh
sed -i 's/\r$//' ~/.ssh/tdd_id_ed25519
printf '\n' >> ~/.ssh/tdd_id_ed25519   # only if the last line lacks a newline
chmod 600 ~/.ssh/tdd_id_ed25519
ssh-keygen -y -f ~/.ssh/tdd_id_ed25519   # must print ssh-ed25519 ... , otherwise the file is truncated
ssh -T git@github.com