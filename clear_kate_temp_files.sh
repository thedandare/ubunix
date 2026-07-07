#!/bin/sh
input_dir="${1:-..}"
target_dir="$2"

if [[ -z "$2" ]]; then
    mkdir -p .old
    target_dir=".old"
fi

find $input_dir -type f -name "*~" -exec mv -t "$target_dir" {} +
find $input_dir -type f -name "*.nix.ba*" -exec mv -t "$target_dir" {} +
find $input_dir -type f -name "*.bkp.ni*" -exec mv -t "$target_dir" {} +

# O que cada parte faz:
# find .: Inicia a busca a partir do diretório atual (.) e entra em todas as subpastas recursivamente.
# -type f: Garante que o comando só vai selecionar arquivos, ignorando pastas que por acaso terminem com ~.-name "*~": Filtra apenas os arquivos cujo nome termina exatamente com o caractere ~.
# -exec mv -t /destino/ {} +: Pega todos os arquivos encontrados e os envia de uma só vez para o comando mv.
# O parâmetro -t (target) diz ao mv qual é a pasta de destino antes de listar os arquivos.
