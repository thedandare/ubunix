
# Forçar a exclusão de todas as instâncias (Contêineres e VMs):
incus delete --force $(incus list -c n --format csv)
# Excluir todas as imagens baixadas/salvas:
incus image delete $(incus image list --format csv | cut -d, -f2)
# Pare o serviço e os sockets do Incus:
sudo systemctl stop incus.service incus.socket incus-preseed.service
#Apague o diretório de dados e bancos de dados:
sudo rm -rf /var/lib/incus/*
